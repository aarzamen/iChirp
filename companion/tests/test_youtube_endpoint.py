"""`POST /v1/youtube/audio` with a fake downloader: allowlist, headers, streaming and temp-folder cleanup."""

from __future__ import annotations

from urllib.parse import unquote

import pytest
from fastapi.testclient import TestClient

from parakeet_companion.app import create_app
from parakeet_companion.config import CompanionSettings

from .fakes import TOKEN, FakeYouTube

LINK = "https://youtu.be/abcdefghijk?si=tracking"


def test_audio_streams_back_with_title_and_duration(client, auth, youtube) -> None:
    response = client.post("/v1/youtube/audio", headers=auth, json={"url": LINK})
    assert response.status_code == 200
    assert response.headers["content-type"] == "audio/mp4"
    assert unquote(response.headers["x-companion-title"]) == "Synthetic title: ünïcode & more"
    assert response.headers["x-companion-title"].isascii()
    assert response.headers["x-companion-duration-ms"] == "61500"
    assert int(response.headers["content-length"]) == len(response.content) > 4_000
    assert response.headers["cache-control"] == "no-store"
    assert youtube.calls == ["https://www.youtube.com/watch?v=abcdefghijk"]


def test_temporary_folder_is_gone_after_the_response(client, auth, youtube) -> None:
    client.post("/v1/youtube/audio", headers=auth, json={"url": LINK})
    assert youtube.workdirs and not youtube.workdirs[0].exists()


def test_no_title_means_no_title_header(auth) -> None:
    app = create_app(CompanionSettings(token=TOKEN), youtube=FakeYouTube(title=None))
    response = TestClient(app).post("/v1/youtube/audio", headers=auth, json={"url": LINK})
    assert response.status_code == 200
    assert "x-companion-title" not in response.headers


@pytest.mark.parametrize(
    "url",
    [
        "https://vimeo.com/12345",
        "https://www.youtube.com.evil.example/watch?v=abcdefghijk",
        "https://evil.example/?u=https://youtu.be/abcdefghijk",
        "ftp://youtube.com/watch?v=abcdefghijk",
        "https://www.youtube.com/playlist?list=PL0123456789",
        "https://www.youtube.com/watch?v=short",
        "https://www.youtube.com/watch?v=abcdefghijk&v=bbbbbbbbbbb",
        "https://user:pw@youtube.com/watch?v=abcdefghijk",
        "https://youtube.com:8080/watch?v=abcdefghijk",
        "https://music.youtube.com/watch?v=abcdefghijk",
        "not a link",
        "",
    ],
)
def test_anything_but_a_single_youtube_video_is_400(client, auth, youtube, url) -> None:
    response = client.post("/v1/youtube/audio", headers=auth, json={"url": url})
    assert response.status_code == 400
    assert response.json()["error"]["code"] == "unsupported_link"
    assert youtube.calls == []
    if url:
        assert url not in response.text


@pytest.mark.parametrize(
    ("outcome", "status", "code"),
    [("unavailable", 422, "video_unavailable"), ("timeout", 504, "youtube_timeout")],
)
def test_errors_clean_up_and_never_echo_the_link(auth, outcome, status, code) -> None:
    youtube = FakeYouTube(outcome=outcome)
    client = TestClient(create_app(CompanionSettings(token=TOKEN), youtube=youtube))
    response = client.post("/v1/youtube/audio", headers=auth, json={"url": LINK})
    assert response.status_code == status
    assert response.json()["error"]["code"] == code
    assert "abcdefghijk" not in response.text and "youtu.be" not in response.text
    assert not youtube.workdirs[0].exists()


def test_deadline_comes_from_settings(auth) -> None:
    youtube = FakeYouTube()
    settings = CompanionSettings(token=TOKEN, youtube_time_limit_seconds=-1)
    response = TestClient(create_app(settings, youtube=youtube)).post(
        "/v1/youtube/audio", headers=auth, json={"url": LINK}
    )
    assert response.status_code == 504


def test_without_yt_dlp_is_503(auth) -> None:
    response = TestClient(create_app(CompanionSettings(token=TOKEN))).post(
        "/v1/youtube/audio", headers=auth, json={"url": LINK}
    )
    assert response.status_code == 503
