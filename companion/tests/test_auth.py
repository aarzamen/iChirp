from __future__ import annotations

import os
import stat

import pytest

from parakeet_companion.auth import (
    MIN_TOKEN_LENGTH,
    TokenFileError,
    generate_token,
    is_authorized,
    load_or_create_token,
)


def test_generated_token_is_32_random_bytes_base64url() -> None:
    token = generate_token()
    assert len(token) == MIN_TOKEN_LENGTH == 43
    assert set(token) <= set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
    assert generate_token() != token


def test_token_file_is_created_owner_only_and_reused(tmp_path) -> None:
    path = tmp_path / "ParakeetCompanion" / "token"
    token, created = load_or_create_token(path)
    assert created
    assert stat.S_IMODE(path.stat().st_mode) == 0o600
    assert stat.S_IMODE(path.parent.stat().st_mode) == 0o700
    again, created_again = load_or_create_token(path)
    assert (again, created_again) == (token, False)


def test_loose_permissions_are_tightened(tmp_path) -> None:
    path = tmp_path / "token"
    path.write_text(generate_token())
    os.chmod(path, 0o644)
    load_or_create_token(path)
    assert stat.S_IMODE(path.stat().st_mode) == 0o600


def test_damaged_token_file_is_refused(tmp_path) -> None:
    path = tmp_path / "token"
    path.write_text("short")
    with pytest.raises(TokenFileError):
        load_or_create_token(path)


@pytest.mark.parametrize(
    ("header", "expected"),
    [
        (None, False),
        ("", False),
        ("Bearer", False),
        ("Bearer wrong", False),
        ("Basic " + "t" * 43, False),
        ("Bearer " + "t" * 42, False),
        ("Bearer " + "t" * 43, True),
        ("bearer " + "t" * 43, True),
        ("  Bearer   " + "t" * 43 + "  ", True),
    ],
)
def test_is_authorized(header, expected) -> None:
    assert is_authorized(header, "t" * 43) is expected


def test_cli_token_file_option_is_used(tmp_path, monkeypatch) -> None:
    """`--token-file` points the companion at another token (a throwaway one for QA), created 0600 like the default."""
    import parakeet_companion.__main__ as cli

    captured: dict = {}

    def fake_run(app, **kwargs) -> None:
        captured["kwargs"] = kwargs

    monkeypatch.setattr("uvicorn.run", fake_run)
    monkeypatch.setattr(cli, "build_backends", lambda: (None, None))
    monkeypatch.setattr(cli, "sweep_stale_downloads", lambda: 0)
    path = tmp_path / "qa-token"
    assert cli.main(["--host", "127.0.0.1", "--port", "8799", "--token-file", str(path), "--advertise-host", "x.local"]) == 0
    assert stat.S_IMODE(path.stat().st_mode) == 0o600
    assert captured["kwargs"]["host"] == "127.0.0.1" and captured["kwargs"]["port"] == 8799
    assert captured["kwargs"]["access_log"] is False
