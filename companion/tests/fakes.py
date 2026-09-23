"""Fakes for the companion's backends: no models, no network."""

from __future__ import annotations

import io
import time
import wave
from pathlib import Path

from parakeet_companion.backends import FetchedAudio, ModelStatus, SpeechAudio, SpeechJob, VoiceInfo
from parakeet_companion.errors import ModelUnavailable, UnknownModel, UnknownVoice, VideoUnavailable, YouTubeTimedOut

TOKEN = "t" * 43


def tiny_wav() -> bytes:
    buffer = io.BytesIO()
    with wave.open(buffer, "wb") as handle:
        handle.setnchannels(1)
        handle.setsampwidth(2)
        handle.setframerate(24_000)
        handle.writeframes(b"\x00\x00" * 240)
    return buffer.getvalue()


class FakeSpeech:
    def __init__(self) -> None:
        self.jobs: list[SpeechJob] = []

    def models(self) -> list[ModelStatus]:
        return [
            ModelStatus("qwen3-tts-1.7b", True),
            ModelStatus("kokoro-82m", False, "run scripts/companion.sh --download kokoro-82m"),
        ]

    def voices(self) -> list[VoiceInfo]:
        return [VoiceInfo("qwen3-tts-1.7b:Ryan", "Ryan", "Dynamic male (US)", ["en"], "qwen3-tts-1.7b", True)]

    def synthesize(self, job: SpeechJob) -> SpeechAudio:
        self.jobs.append(job)
        if job.model == "kokoro-82m":
            raise ModelUnavailable("kokoro-82m is not downloaded. Run: scripts/companion.sh --download kokoro-82m")
        if job.model != "qwen3-tts-1.7b":
            raise UnknownModel("Unknown model.")
        if job.voice != "Ryan":
            raise UnknownVoice("Unknown voice.")
        if job.response_format == "wav":
            return SpeechAudio(tiny_wav(), "audio/wav")
        return SpeechAudio(b"ID3fake-mp3", "audio/mpeg")


class FakeYouTube:
    """Writes a small fake m4a into the work folder, or raises what `outcome` says."""

    def __init__(self, outcome: str = "ok", title: str | None = "Synthetic title: ünïcode & more") -> None:
        self.outcome = outcome
        self.title = title
        self.calls: list[str] = []
        self.workdirs: list[Path] = []

    def is_available(self) -> bool:
        return True

    def fetch_audio(self, video_url: str, workdir: Path, deadline: float) -> FetchedAudio:
        self.calls.append(video_url)
        self.workdirs.append(workdir)
        if self.outcome == "unavailable":
            raise VideoUnavailable("This video is unavailable.")
        if self.outcome == "timeout" or time.monotonic() > deadline:
            raise YouTubeTimedOut("The download took longer than 15 minutes.")
        path = workdir / "audio.m4a"
        path.write_bytes(b"\x00\x00\x00\x18ftypM4A " + b"\x01" * 4096)
        return FetchedAudio(path=path, title=self.title, duration_ms=61_500)
