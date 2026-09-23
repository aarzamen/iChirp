"""The pairing token: 32 random bytes (base64url), created on first start, kept in a 0600 file on this Mac."""

from __future__ import annotations

import base64
import os
import secrets
import stat
from pathlib import Path

TOKEN_BYTES = 32
#: base64url of 32 bytes without padding is 43 characters; anything shorter is not a token this companion made.
MIN_TOKEN_LENGTH = 43


class TokenFileError(RuntimeError):
    """The token file exists but cannot be used (unreadable, empty or too short)."""


def generate_token() -> str:
    return base64.urlsafe_b64encode(secrets.token_bytes(TOKEN_BYTES)).rstrip(b"=").decode("ascii")


def load_or_create_token(path: Path) -> tuple[str, bool]:
    """Returns the token at `path` and whether it was just created.

    The folder is created 0700 and the file 0600 (owner only). An existing file with looser permissions is tightened.
    """
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    try:
        descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    except FileExistsError:
        return _read_existing(path), False
    token = generate_token()
    with os.fdopen(descriptor, "w", encoding="ascii") as handle:
        handle.write(token + "\n")
    os.chmod(path, 0o600)
    return token, True


def _read_existing(path: Path) -> str:
    mode = stat.S_IMODE(path.stat().st_mode)
    if mode & 0o077:
        os.chmod(path, 0o600)
    try:
        token = path.read_text(encoding="ascii").strip()
    except (OSError, UnicodeDecodeError) as error:
        raise TokenFileError(f"The pairing token file cannot be read: {type(error).__name__}") from None
    if len(token) < MIN_TOKEN_LENGTH:
        raise TokenFileError(f"The pairing token file is empty or damaged. Delete it to make a new token: {path}")
    return token


def is_authorized(authorization: str | None, token: str) -> bool:
    """True when `authorization` is exactly `Bearer <token>` (scheme case-insensitive), compared in constant time."""
    if not authorization:
        return False
    scheme, _, value = authorization.strip().partition(" ")
    if scheme.lower() != "bearer":
        return False
    return secrets.compare_digest(value.strip().encode("utf-8"), token.encode("utf-8"))
