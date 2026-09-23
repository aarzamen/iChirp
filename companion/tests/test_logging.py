"""The request log carries method, a known path, status, sizes and milliseconds — never content."""

from __future__ import annotations

import logging

SECRET_TEXT = "Patient Jane Roe has chest pain"
SECRET_LINK = "https://www.youtube.com/watch?v=abcdefghijk"


def _messages(caplog) -> list[str]:
    return [record.getMessage() for record in caplog.records if record.name == "parakeet_companion"]


def test_request_bodies_links_and_tokens_never_reach_the_log(client, auth, caplog) -> None:
    caplog.set_level(logging.DEBUG)
    client.post("/v1/audio/speech", headers=auth, json={"model": "qwen3-tts-1.7b", "input": SECRET_TEXT, "voice": "Ryan"})
    client.post("/v1/audio/speech", headers=auth, json={"model": "nope", "input": SECRET_TEXT, "voice": "Ryan"})
    client.post("/v1/youtube/audio", headers=auth, json={"url": SECRET_LINK})
    client.post("/v1/youtube/audio", headers=auth, json={"url": "https://example.com/" + SECRET_TEXT})
    client.get("/v1/" + SECRET_TEXT.replace(" ", "-"), headers=auth)
    client.get("/v1/voices?q=" + SECRET_TEXT.replace(" ", "+"), headers=auth)
    client.get("/v1/voices", headers={"Authorization": "Bearer " + SECRET_TEXT})
    messages = _messages(caplog)
    assert len(messages) >= 7
    joined = "\n".join(messages)
    for needle in ("Patient", "Jane", "chest", "abcdefghijk", "example.com", "youtube.com", "Synthetic title", "t" * 43):
        assert needle not in joined


def test_log_lines_have_only_the_allowed_fields(client, auth, caplog) -> None:
    caplog.set_level(logging.INFO)
    client.get("/v1/companion")
    client.get("/v1/voices", headers=auth)
    client.get("/v1/not-a-route", headers=auth)
    lines = [line for line in _messages(caplog) if line.startswith("request ")]
    assert lines[0].startswith("request method=GET path=/v1/companion status=200 bytes_in=0 bytes_out=")
    assert lines[1].startswith("request method=GET path=/v1/voices status=200 ")
    assert lines[2].startswith("request method=GET path=other status=404 ")
    for line in lines:
        keys = [part.split("=")[0] for part in line.split()[1:]]
        assert keys == ["method", "path", "status", "bytes_in", "bytes_out", "ms"]
