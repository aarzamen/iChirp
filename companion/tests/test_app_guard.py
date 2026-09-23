"""The pairing-token guard, the body limit and the health endpoint (Step 1)."""

from __future__ import annotations

import pytest

from .fakes import TOKEN


def test_health_needs_no_token_and_reports_features(client) -> None:
    response = client.get("/v1/companion")
    assert response.status_code == 200
    body = response.json()
    assert body["name"] == "Parakeet companion"
    assert body["api"] == "mac-companion-v1"
    assert body["version"] == "1.0.0"
    assert body["features"] == {"speech": True, "youtubeAudio": True}
    assert body["speech"] == {"models": ["qwen3-tts-1.7b"], "defaultModel": "qwen3-tts-1.7b"}


def test_health_without_backends_reports_false() -> None:
    from fastapi.testclient import TestClient

    from parakeet_companion.app import create_app
    from parakeet_companion.config import CompanionSettings

    body = TestClient(create_app(CompanionSettings(token=TOKEN))).get("/v1/companion").json()
    assert body["features"] == {"speech": False, "youtubeAudio": False}
    assert body["speech"] == {"models": [], "defaultModel": None}


@pytest.mark.parametrize(
    "headers",
    [{}, {"Authorization": "Bearer wrong"}, {"Authorization": "Basic " + TOKEN}, {"Authorization": TOKEN}],
)
def test_voices_without_or_with_wrong_token_is_401(client, headers) -> None:
    response = client.get("/v1/voices", headers=headers)
    assert response.status_code == 401
    assert response.json()["error"]["code"] == "unauthorized"


def test_voices_with_token(client, auth) -> None:
    response = client.get("/v1/voices", headers=auth)
    assert response.status_code == 200
    assert response.json() == {
        "voices": [
            {
                "id": "qwen3-tts-1.7b:Ryan",
                "name": "Ryan",
                "detail": "Dynamic male (US)",
                "languages": ["en"],
                "model": "qwen3-tts-1.7b",
                "supportsStyle": True,
            }
        ]
    }


@pytest.mark.parametrize(
    ("method", "path"),
    [
        ("POST", "/v1/audio/speech"),
        ("POST", "/v1/youtube/audio"),
        ("GET", "/docs"),
        ("GET", "/openapi.json"),
        ("GET", "/anything"),
        ("POST", "/v1/companion"),
    ],
)
def test_every_other_request_needs_the_token(client, method, path) -> None:
    assert client.request(method, path, json={}).status_code == 401


def test_docs_are_off_even_with_the_token(client, auth) -> None:
    for path in ("/docs", "/redoc", "/openapi.json"):
        response = client.get(path, headers=auth)
        assert response.status_code == 404
        assert response.json()["error"]["code"] == "not_found"


def test_oversized_body_is_413_before_it_is_read(client, auth) -> None:
    response = client.post(
        "/v1/audio/speech", headers={**auth, "Content-Type": "application/json"}, content=b"{" + b" " * 70_000 + b"}"
    )
    assert response.status_code == 413
    assert response.json()["error"]["code"] == "payload_too_large"
