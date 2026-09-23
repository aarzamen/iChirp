"""Constants and settings of the Parakeet companion (spec/contracts/mac-companion-v1.md)."""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

NAME = "Parakeet companion"
VERSION = "1.0.0"
API = "mac-companion-v1"

DEFAULT_HOST = "0.0.0.0"
DEFAULT_PORT = 8765

#: The one path that answers without the pairing token.
HEALTH_PATH = "/v1/companion"
VOICES_PATH = "/v1/voices"
SPEECH_PATH = "/v1/audio/speech"
YOUTUBE_PATH = "/v1/youtube/audio"
#: Paths the request log may name. Anything else is logged as "other", so a path can never carry content into a log.
KNOWN_PATHS = frozenset({HEALTH_PATH, VOICES_PATH, SPEECH_PATH, YOUTUBE_PATH})

#: `input` longer than this is refused with 413 (contract).
MAX_INPUT_CHARACTERS = 4_000
#: Request bodies larger than this are refused with 413 before they are read (4 000 characters of JSON fit easily).
MAX_BODY_BYTES = 64 * 1_024
#: The YouTube download wall limit (contract: 504 above it).
YOUTUBE_TIME_LIMIT_SECONDS = 15 * 60


def support_directory() -> Path:
    """`~/Library/Application Support/ParakeetCompanion`: the pairing token lives here, nothing else."""
    return Path.home() / "Library" / "Application Support" / "ParakeetCompanion"


def token_path() -> Path:
    return support_directory() / "token"


@dataclass(frozen=True)
class CompanionSettings:
    """What one running companion needs. Built once at start; tests build their own."""

    token: str
    max_input_characters: int = MAX_INPUT_CHARACTERS
    max_body_bytes: int = MAX_BODY_BYTES
    youtube_time_limit_seconds: float = YOUTUBE_TIME_LIMIT_SECONDS
