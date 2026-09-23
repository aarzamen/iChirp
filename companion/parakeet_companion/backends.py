"""The two jobs the companion does, behind protocols so tests use fakes (no models, no network)."""

from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path
from typing import Protocol


@dataclass(frozen=True)
class VoiceInfo:
    """One voice as `GET /v1/voices` lists it."""

    id: str
    name: str
    detail: str
    languages: list[str]
    model: str
    supports_style: bool

    def as_json(self) -> dict:
        return {
            "id": self.id,
            "name": self.name,
            "detail": self.detail,
            "languages": list(self.languages),
            "model": self.model,
            "supportsStyle": self.supports_style,
        }


@dataclass(frozen=True)
class ModelStatus:
    """A speech model the companion knows, and whether it can run now (else `reason` says how to fix it)."""

    id: str
    available: bool
    reason: str | None = None


@dataclass(frozen=True)
class SpeechJob:
    """One `POST /v1/audio/speech` request, already validated. Held in memory for the request only."""

    model: str
    text: str
    voice: str
    instructions: str | None = None
    language: str | None = None
    response_format: str = "mp3"


@dataclass(frozen=True)
class SpeechAudio:
    data: bytes
    media_type: str


class SpeechBackend(Protocol):
    def models(self) -> list[ModelStatus]:
        """Every model this companion knows, available or not. Cheap: no model is loaded."""

    def voices(self) -> list[VoiceInfo]:
        """Voices of the available models."""

    def synthesize(self, job: SpeechJob) -> SpeechAudio:
        """Speaks `job.text`. Raises `CompanionError` subclasses (unknown model or voice, model unavailable, …)."""


@dataclass(frozen=True)
class FetchedAudio:
    """A downloaded audio file inside the request's temporary folder."""

    path: Path
    title: str | None
    duration_ms: int | None
    media_type: str = "audio/mp4"
    extra: dict = field(default_factory=dict)


class YouTubeBackend(Protocol):
    def is_available(self) -> bool:
        """Whether the downloader is installed."""

    def fetch_audio(self, video_url: str, workdir: Path, deadline: float) -> FetchedAudio:
        """Downloads the audio of the canonical `video_url` into `workdir` before `deadline` (`time.monotonic()`).

        Raises `VideoUnavailable`, `YouTubeFailed` or `YouTubeTimedOut`.
        """
