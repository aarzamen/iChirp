"""`POST /v1/audio/speech` with a fake synthesizer: shape, limits, errors and content types."""

from __future__ import annotations

import pytest

BODY = {"model": "qwen3-tts-1.7b", "input": "Hello from Parakeet.", "voice": "Ryan"}


def test_mp3_by_default(client, auth, speech) -> None:
    response = client.post("/v1/audio/speech", headers=auth, json=BODY)
    assert response.status_code == 200
    assert response.headers["content-type"] == "audio/mpeg"
    assert response.content.startswith(b"ID3")
    assert speech.jobs[0].response_format == "mp3"


def test_wav_on_request(client, auth) -> None:
    response = client.post("/v1/audio/speech", headers=auth, json={**BODY, "response_format": "wav"})
    assert response.status_code == 200
    assert response.headers["content-type"] == "audio/wav"
    assert response.content[:4] == b"RIFF" and response.content[8:12] == b"WAVE"


def test_style_language_and_extra_fields_pass_through(client, auth, speech) -> None:
    body = {**BODY, "instructions": "  calm and slow  ", "language": "en", "speed": 1.2, "stream": False}
    assert client.post("/v1/audio/speech", headers=auth, json=body).status_code == 200
    job = speech.jobs[0]
    assert (job.instructions, job.language, job.voice, job.model) == ("calm and slow", "en", "Ryan", "qwen3-tts-1.7b")


def test_exactly_4000_characters_is_allowed(client, auth) -> None:
    assert client.post("/v1/audio/speech", headers=auth, json={**BODY, "input": "a" * 4000}).status_code == 200


def test_over_4000_characters_is_413(client, auth, speech) -> None:
    response = client.post("/v1/audio/speech", headers=auth, json={**BODY, "input": "a" * 4001})
    assert response.status_code == 413
    assert response.json()["error"]["code"] == "input_too_long"
    assert speech.jobs == []


@pytest.mark.parametrize(
    ("body", "status", "code"),
    [
        ({**BODY, "model": "whisper-9000"}, 400, "unknown_model"),
        ({**BODY, "voice": "Nobody"}, 400, "unknown_voice"),
        ({**BODY, "model": "kokoro-82m"}, 503, "model_unavailable"),
        ({**BODY, "response_format": "ogg"}, 400, "bad_request"),
        ({"model": "qwen3-tts-1.7b", "voice": "Ryan"}, 400, "bad_request"),
        ({**BODY, "input": "   "}, 400, "bad_request"),
        ({**BODY, "voice": ""}, 400, "bad_request"),
    ],
)
def test_errors(client, auth, body, status, code) -> None:
    response = client.post("/v1/audio/speech", headers=auth, json=body)
    assert response.status_code == status
    assert response.json()["error"]["code"] == code
    assert "message" in response.json()["error"]


def test_503_names_the_fixing_command(client, auth) -> None:
    response = client.post("/v1/audio/speech", headers=auth, json={**BODY, "model": "kokoro-82m"})
    assert "scripts/companion.sh --download kokoro-82m" in response.json()["error"]["message"]


def test_validation_errors_never_echo_the_text(client, auth) -> None:
    secret = "Patient Jane Roe"
    response = client.post("/v1/audio/speech", headers=auth, json={**BODY, "input": secret, "response_format": 7})
    assert response.status_code == 400
    assert secret not in response.text


def test_not_json_is_400(client, auth) -> None:
    response = client.post(
        "/v1/audio/speech", headers={**auth, "Content-Type": "application/json"}, content=b"not json"
    )
    assert response.status_code == 400
