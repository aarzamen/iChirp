"""The pairing-token guard, the body limit and the health endpoint (Step 1)."""

from __future__ import annotations

import pytest
from starlette.websockets import WebSocket, WebSocketDisconnect

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


def test_health_reports_youtube_off_with_the_reason_when_deno_is_missing(auth) -> None:
    from fastapi.testclient import TestClient

    from parakeet_companion.app import create_app
    from parakeet_companion.config import CompanionSettings
    from parakeet_companion.youtube import YtDlpBackend

    app = create_app(CompanionSettings(token=TOKEN), youtube=YtDlpBackend(find_executable=lambda name: None))
    client = TestClient(app)
    body = client.get("/v1/companion").json()
    assert body["features"]["youtubeAudio"] is False
    assert "deno" in body["youtube"]["reason"]
    response = client.post("/v1/youtube/audio", headers=auth, json={"url": "https://youtu.be/abcdefghijk"})
    assert response.status_code == 503
    assert "deno" in response.json()["error"]["message"]


def test_health_has_no_youtube_reason_when_ready(client) -> None:
    assert client.get("/v1/companion").json()["youtube"] == {"reason": None}


# MARK: Websockets and the lifespan (review R8-20): the guard runs before any route, whatever the connection type.


@pytest.fixture
def socket_client(client):
    """The client with a websocket route the real companion does not have (yet): what a future route would face.

    `WebSocket` is imported at module level on purpose: with `from __future__ import annotations` FastAPI resolves
    the route's annotations from the module's globals, and an unresolved one turns the parameter into a required
    query field, which closes the socket with 1008 for the wrong reason.
    """

    @client.app.websocket("/v1/test-socket")
    async def socket_route(websocket: WebSocket) -> None:
        await websocket.accept()
        await websocket.send_text("connected")
        await websocket.close()

    return client


@pytest.mark.parametrize(
    "headers",
    [{}, {"Authorization": "Bearer wrong"}, {"Authorization": "Basic " + TOKEN}, {"Authorization": TOKEN}],
)
def test_a_websocket_without_the_right_token_is_refused_before_any_route_runs(socket_client, headers) -> None:
    with pytest.raises(WebSocketDisconnect) as refused:
        with socket_client.websocket_connect("/v1/test-socket", headers=headers):
            pass
    assert refused.value.code == 1008
    assert refused.value.reason == ""  # the route never ran, and nothing says why beyond the close code


def test_a_websocket_with_the_token_reaches_its_route(socket_client, auth) -> None:
    with socket_client.websocket_connect("/v1/test-socket", headers=auth) as socket:
        assert socket.receive_text() == "connected"


def test_a_refused_websocket_is_logged_without_content(socket_client, caplog) -> None:
    caplog.set_level("INFO", logger="parakeet_companion")
    with pytest.raises(WebSocketDisconnect):
        with socket_client.websocket_connect("/v1/test-socket?note=SYNTHETIC-SECRET-7731"):
            pass
    assert "websocket_refused" in caplog.text
    assert "SYNTHETIC-SECRET-7731" not in caplog.text


def test_the_lifespan_still_passes_through_the_guard() -> None:
    from fastapi.testclient import TestClient

    from parakeet_companion.app import create_app
    from parakeet_companion.config import CompanionSettings

    with TestClient(create_app(CompanionSettings(token=TOKEN))) as started:  # runs startup and shutdown
        assert started.get("/v1/companion").status_code == 200
