"""The link allowlist, error mapping and `YtDlpBackend` against a fake `yt_dlp.YoutubeDL`."""

from __future__ import annotations

import time

import pytest
import yt_dlp
from yt_dlp.utils import DownloadError

from parakeet_companion.errors import UnsupportedLink, VideoUnavailable, YouTubeFailed, YouTubeTimedOut
from parakeet_companion.youtube import YtDlpBackend, _QuietLogger, canonical_video_url, classify, sanitized_error

CANONICAL = "https://www.youtube.com/watch?v=abcdefghijk"


@pytest.mark.parametrize(
    "url",
    [
        "https://www.youtube.com/watch?v=abcdefghijk",
        "http://youtube.com/watch?v=abcdefghijk&t=42s&list=PL0123",
        "https://m.youtube.com/watch/?v=abcdefghijk",
        "https://youtu.be/abcdefghijk",
        "https://youtu.be/abcdefghijk?si=xyz",
        "https://www.youtube.com/shorts/abcdefghijk",
        "https://www.youtube.com/live/abcdefghijk?feature=share",
        "https://www.youtube.com/embed/abcdefghijk",
        "  HTTPS://WWW.YOUTUBE.COM/watch?v=abcdefghijk  ",
    ],
)
def test_single_video_links_become_canonical(url) -> None:
    assert canonical_video_url(url) == CANONICAL


def test_sanitized_error_drops_prefix_link_and_id() -> None:
    line = "ERROR: [youtube] abcdefghijk: Requested format is not available. See https://github.com/yt-dlp/x"
    assert sanitized_error(line, CANONICAL) == "Requested format is not available."
    assert sanitized_error("", CANONICAL) == "yt-dlp could not download this video."


@pytest.mark.parametrize(
    ("line", "kind"),
    [
        ("ERROR: [youtube] abcdefghijk: Video unavailable", VideoUnavailable),
        ("ERROR: [youtube] abcdefghijk: Private video. Sign in if you've been granted access", VideoUnavailable),
        ("ERROR: [youtube] abcdefghijk: Sign in to confirm your age.", VideoUnavailable),
        ("ERROR: [youtube] abcdefghijk: This live event will begin in 3 hours.", VideoUnavailable),
        ("ERROR: [youtube] abcdefghijk: Sign in to confirm you’re not a bot", YouTubeFailed),
        ("ERROR: unable to download video data: HTTP Error 403: Forbidden", YouTubeFailed),
    ],
)
def test_classify(line, kind) -> None:
    error = classify(line, CANONICAL)
    assert isinstance(error, kind)
    assert "abcdefghijk" not in error.message


class FakeYDL:
    """Stands in for `yt_dlp.YoutubeDL`: `info` is what extraction returns; `fail` makes a step raise."""

    info: dict = {}
    fail: str | None = None
    write = True

    def __init__(self, options: dict) -> None:
        self.options = options

    def __enter__(self):
        return self

    def __exit__(self, *exc) -> None:
        return None

    def extract_info(self, url, download=False):
        assert url == CANONICAL and download is False
        if self.fail == "extract":
            self.options["logger"].error("ERROR: [youtube] abcdefghijk: Video unavailable")
            raise DownloadError("ERROR: [youtube] abcdefghijk: Video unavailable")
        return dict(self.info)

    def process_ie_result(self, info, download=True):
        home = self.options["paths"]["home"]
        for hook in self.options["progress_hooks"]:
            hook({"status": "downloading"})
        if self.fail == "download":
            raise RuntimeError("socket blew up for " + CANONICAL)
        if self.write:
            path = f"{home}/audio.m4a"
            with open(path, "wb") as handle:
                handle.write(b"m4a" * 100)
            info["requested_downloads"] = [{"filepath": path}]
        return info


@pytest.fixture
def fake_ydl(monkeypatch):
    FakeYDL.info = {"id": "abcdefghijk", "title": "A synthetic title", "duration": 12.5, "live_status": "not_live"}
    FakeYDL.fail = None
    FakeYDL.write = True
    monkeypatch.setattr(yt_dlp, "YoutubeDL", FakeYDL)
    return FakeYDL


def test_backend_downloads_title_and_duration(fake_ydl, tmp_path) -> None:
    fetched = YtDlpBackend().fetch_audio(CANONICAL, tmp_path, time.monotonic() + 60)
    assert fetched.path == tmp_path / "audio.m4a"
    assert (fetched.title, fetched.duration_ms, fetched.media_type) == ("A synthetic title", 12_500, "audio/mp4")


def test_backend_options_are_single_video_m4a(fake_ydl, tmp_path) -> None:
    options = YtDlpBackend().options(tmp_path, time.monotonic() + 60, _QuietLogger())
    assert options["noplaylist"] is True
    assert options["format"].startswith("bestaudio[ext=m4a]")
    assert options["cachedir"] is False and options["writeinfojson"] is False


def test_live_is_422(fake_ydl, tmp_path) -> None:
    fake_ydl.info = {**fake_ydl.info, "live_status": "is_live"}
    with pytest.raises(VideoUnavailable):
        YtDlpBackend().fetch_audio(CANONICAL, tmp_path, time.monotonic() + 60)


def test_extraction_error_is_classified(fake_ydl, tmp_path) -> None:
    fake_ydl.fail = "extract"
    with pytest.raises(VideoUnavailable):
        YtDlpBackend().fetch_audio(CANONICAL, tmp_path, time.monotonic() + 60)


def test_unexpected_error_reports_type_only(fake_ydl, tmp_path) -> None:
    fake_ydl.fail = "download"
    with pytest.raises(YouTubeFailed) as raised:
        YtDlpBackend().fetch_audio(CANONICAL, tmp_path, time.monotonic() + 60)
    assert "RuntimeError" in raised.value.message and "youtube" not in raised.value.message


def test_passed_deadline_is_504(fake_ydl, tmp_path) -> None:
    with pytest.raises(YouTubeTimedOut):
        YtDlpBackend().fetch_audio(CANONICAL, tmp_path, time.monotonic() - 1)


def test_no_file_is_502(fake_ydl, tmp_path) -> None:
    fake_ydl.write = False
    with pytest.raises(YouTubeFailed):
        YtDlpBackend().fetch_audio(CANONICAL, tmp_path, time.monotonic() + 60)


def test_unsupported_link_error_type() -> None:
    with pytest.raises(UnsupportedLink):
        canonical_video_url("https://example.com")


def test_without_a_javascript_runtime_youtube_is_off_with_the_reason() -> None:
    # Review L1 M5: yt-dlp needs deno for YouTube; without it every fetch would fail, so health says so up front.
    missing = YtDlpBackend(find_executable=lambda name: None)
    assert missing.is_available() is False
    reason = missing.unavailable_reason()
    assert reason is not None and "deno" in reason and "brew install deno" in reason
    ready = YtDlpBackend(find_executable=lambda name: f"/opt/homebrew/bin/{name}")
    assert ready.is_available() is True
    assert ready.unavailable_reason() is None
