"""Encodes synthesized samples: WAV with the standard library, MP3 with Homebrew's ffmpeg in a subprocess.

Nothing is written to disk: PCM goes to ffmpeg's stdin and the MP3 comes back on its stdout.
"""

from __future__ import annotations

import io
import shutil
import subprocess
import wave
from pathlib import Path

import numpy as np

from .errors import EncoderUnavailable, SynthesisFailed

MEDIA_TYPES = {"mp3": "audio/mpeg", "wav": "audio/wav"}
_FFMPEG_FALLBACKS = (Path("/opt/homebrew/bin/ffmpeg"), Path("/usr/local/bin/ffmpeg"))


def to_pcm16(samples: np.ndarray) -> bytes:
    """Mono float samples in [-1, 1] as little-endian 16-bit PCM."""
    mono = np.asarray(samples, dtype=np.float32).reshape(-1)
    clipped = np.clip(np.nan_to_num(mono), -1.0, 1.0)
    return (clipped * 32767.0).astype("<i2").tobytes()


def encode_wav(samples: np.ndarray, sample_rate: int) -> bytes:
    buffer = io.BytesIO()
    with wave.open(buffer, "wb") as handle:
        handle.setnchannels(1)
        handle.setsampwidth(2)
        handle.setframerate(int(sample_rate))
        handle.writeframes(to_pcm16(samples))
    return buffer.getvalue()


def ffmpeg_path() -> str | None:
    found = shutil.which("ffmpeg")
    if found:
        return found
    for candidate in _FFMPEG_FALLBACKS:
        if candidate.is_file():
            return str(candidate)
    return None


def require_encoder(response_format: str) -> None:
    """Raises before any synthesis when the format cannot be produced on this Mac."""
    if response_format == "mp3" and ffmpeg_path() is None:
        raise EncoderUnavailable(
            "MP3 needs ffmpeg on the Mac. Install it with `brew install ffmpeg`, or ask for WAV."
        )


def encode_mp3(samples: np.ndarray, sample_rate: int, ffmpeg: str | None = None) -> bytes:
    executable = ffmpeg or ffmpeg_path()
    if executable is None:
        raise EncoderUnavailable("MP3 needs ffmpeg on the Mac. Install it with `brew install ffmpeg`, or ask for WAV.")
    command = [
        executable, "-hide_banner", "-loglevel", "error", "-nostdin",
        "-f", "s16le", "-ar", str(int(sample_rate)), "-ac", "1", "-i", "pipe:0",
        "-b:a", "128k", "-f", "mp3", "pipe:1",
    ]  # fmt: skip
    try:
        result = subprocess.run(command, input=to_pcm16(samples), capture_output=True, timeout=300, check=False)
    except (OSError, subprocess.SubprocessError) as error:
        raise SynthesisFailed(f"Encoding MP3 failed on the Mac ({type(error).__name__}).") from None
    if result.returncode != 0 or not result.stdout:
        raise SynthesisFailed("Encoding MP3 failed on the Mac (ffmpeg returned an error).")
    return result.stdout


def encode(samples: np.ndarray, sample_rate: int, response_format: str) -> tuple[bytes, str]:
    """The encoded bytes and their media type."""
    if response_format == "wav":
        return encode_wav(samples, sample_rate), MEDIA_TYPES["wav"]
    return encode_mp3(samples, sample_rate), MEDIA_TYPES["mp3"]
