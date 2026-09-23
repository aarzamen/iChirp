"""YouTube audio for videos without captions, through yt-dlp's Python API.

Only single-video links on youtube.com, www.youtube.com, m.youtube.com and youtu.be are accepted; the link is reduced
to its canonical `https://www.youtube.com/watch?v=<id>` form before yt-dlp sees it (no playlists, no extra
parameters). The audio lands in the request's temporary folder, which the endpoint deletes when the response ends.
Error messages never echo the link or the video id.
"""

from __future__ import annotations

import importlib.util
import re
import shutil
import time
from collections.abc import Callable
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any
from urllib.parse import parse_qs, urlsplit

from .backends import FetchedAudio
from .errors import CompanionError, UnsupportedLink, VideoUnavailable, YouTubeFailed, YouTubeTimedOut

ALLOWED_HOSTS = frozenset({"youtube.com", "www.youtube.com", "m.youtube.com", "youtu.be"})
_VIDEO_ID = re.compile(r"^[A-Za-z0-9_-]{11}$")
_PATH_ID = re.compile(r"^/(?:shorts|live|embed|v)/([^/]+)/?$")

UNSUPPORTED_HOST = "Only youtube.com, youtu.be and m.youtube.com links are accepted."
NOT_A_VIDEO = "That is not a link to a single YouTube video."
TIMED_OUT = "Downloading the audio took longer than 15 minutes, so the Mac stopped."


def canonical_video_url(raw: str) -> str:
    """`https://www.youtube.com/watch?v=<id>` for a single-video link, else `UnsupportedLink` (400)."""
    try:
        parsed = urlsplit(raw.strip())
        port = parsed.port
    except ValueError:
        raise UnsupportedLink(UNSUPPORTED_HOST) from None
    host = (parsed.hostname or "").lower().rstrip(".")
    if parsed.scheme.lower() not in ("http", "https") or host not in ALLOWED_HOSTS:
        raise UnsupportedLink(UNSUPPORTED_HOST)
    if parsed.username or parsed.password or port not in (None, 80, 443):
        raise UnsupportedLink(UNSUPPORTED_HOST)
    if host == "youtu.be":
        video_id = parsed.path.strip("/")
    elif parsed.path.rstrip("/") == "/watch":
        values = parse_qs(parsed.query).get("v", [])
        video_id = values[0] if len(values) == 1 else ""
    else:
        match = _PATH_ID.match(parsed.path)
        video_id = match.group(1) if match else ""
    if not _VIDEO_ID.match(video_id):
        raise UnsupportedLink(NOT_A_VIDEO)
    return f"https://www.youtube.com/watch?v={video_id}"


def sanitized_error(line: str, video_url: str) -> str:
    """yt-dlp's first error line without its prefix, the link or the video id, at most 200 characters."""
    video_id = video_url.rsplit("=", 1)[-1]
    text = line.strip().splitlines()[0] if line.strip() else ""
    text = re.sub(r"^(ERROR:\s*)+", "", text)
    text = re.sub(r"\[[^\]]+\]\s*", "", text)
    text = re.sub(r"https?://\S+", "", text)
    if video_id:
        text = text.replace(video_id, "")
    text = re.sub(r"^\s*:\s*", "", text)
    text = re.sub(r"\s{2,}", " ", text).strip(" :")
    # "… See https://…" loses its link above; drop the dangling "See" (or "see") too.
    text = re.sub(r"\s*\b[Ss]ee\s*\.?$", "", text).strip(" :")
    return text[:200] or "yt-dlp could not download this video."


def classify(line: str, video_url: str) -> Exception:
    """Maps yt-dlp's error text to the contract's statuses (422 unavailable, 502 other)."""
    lowered = line.lower()
    if "confirm your age" in lowered or "age-restricted" in lowered or "inappropriate for some users" in lowered:
        return VideoUnavailable("This video is age-restricted, so it cannot be downloaded without signing in.")
    if "not a bot" in lowered:
        return YouTubeFailed("YouTube asked the Mac for a sign-in (a robot check). Try again later.")
    if "live event will begin" in lowered or "premieres in" in lowered or "is live" in lowered:
        return VideoUnavailable("This is a live stream or premiere that has not finished, so there is no audio yet.")
    if any(
        needle in lowered
        for needle in ("video unavailable", "private video", "has been removed", "is not available", "does not exist")
    ):
        return VideoUnavailable("This video is unavailable (private, removed or the link is wrong).")
    return YouTubeFailed(sanitized_error(line, video_url))


class _DeadlinePassed(Exception):
    pass


class _QuietLogger:
    """Swallows yt-dlp's output (it names links and titles) and keeps error lines for the sanitized message."""

    def __init__(self) -> None:
        self.errors: list[str] = []

    def debug(self, message: str) -> None:
        pass

    def info(self, message: str) -> None:
        pass

    def warning(self, message: str) -> None:
        pass

    def error(self, message: str) -> None:
        self.errors.append(str(message))


NO_JS_RUNTIME = (
    "YouTube audio needs deno, the JavaScript runtime yt-dlp uses for YouTube. Install it on the Mac "
    "(brew install deno), then restart the companion."
)


@dataclass
class YtDlpBackend:
    """`YouTubeBackend` on yt-dlp: `bestaudio[ext=m4a]`, no playlists, a wall-clock deadline. YouTube also needs
    deno on the PATH (yt-dlp solves YouTube's JavaScript challenges with it); without it every fetch fails, so the
    backend reports itself unavailable with that reason (health `youtubeAudio: false`)."""

    audio_format = "bestaudio[ext=m4a]/bestaudio[acodec^=mp4a]"
    find_executable: Callable[[str], str | None] = field(default=shutil.which)

    def unavailable_reason(self) -> str | None:
        if importlib.util.find_spec("yt_dlp") is None:
            return "YouTube audio needs yt-dlp. Run: uv sync --project companion"
        if self.find_executable("deno") is None:
            return NO_JS_RUNTIME
        return None

    def is_available(self) -> bool:
        return self.unavailable_reason() is None

    def options(self, workdir: Path, deadline: float, quiet: _QuietLogger) -> dict[str, Any]:
        def enforce_deadline(_status: dict) -> None:
            if time.monotonic() > deadline:
                raise _DeadlinePassed()

        return {
            "format": self.audio_format,
            "noplaylist": True,
            "paths": {"home": str(workdir), "temp": str(workdir)},
            "outtmpl": {"default": "audio.%(ext)s"},
            "quiet": True,
            "no_warnings": True,
            "noprogress": True,
            "logger": quiet,
            "progress_hooks": [enforce_deadline],
            "socket_timeout": 30,
            "retries": 3,
            "cachedir": False,
            "overwrites": True,
            "writethumbnail": False,
            "writesubtitles": False,
            "writeinfojson": False,
            "consoletitle": False,
            "no_color": True,
        }

    def fetch_audio(self, video_url: str, workdir: Path, deadline: float) -> FetchedAudio:
        import yt_dlp
        from yt_dlp.utils import DownloadError

        quiet = _QuietLogger()
        try:
            with yt_dlp.YoutubeDL(self.options(workdir, deadline, quiet)) as ydl:
                info = ydl.extract_info(video_url, download=False)
                if not isinstance(info, dict) or info.get("_type") == "playlist":
                    raise UnsupportedLink(NOT_A_VIDEO)
                if info.get("is_live") or info.get("live_status") in ("is_live", "is_upcoming"):
                    raise VideoUnavailable(
                        "This is a live stream or premiere that has not finished, so there is no audio yet."
                    )
                if time.monotonic() > deadline:
                    raise YouTubeTimedOut(TIMED_OUT)
                info = ydl.process_ie_result(info, download=True)
        except _DeadlinePassed:
            raise YouTubeTimedOut(TIMED_OUT) from None
        except DownloadError as error:
            cause = error.exc_info[1] if getattr(error, "exc_info", None) else None
            if isinstance(cause, _DeadlinePassed):
                raise YouTubeTimedOut(TIMED_OUT) from None
            raise classify(quiet.errors[0] if quiet.errors else str(error), video_url) from None
        except CompanionError:
            raise
        except Exception as error:  # noqa: BLE001 — type only; yt-dlp's messages name the link
            raise YouTubeFailed(f"yt-dlp failed on the Mac ({type(error).__name__}).") from None
        path = self._downloaded_file(info, workdir)
        duration = info.get("duration")
        title = info.get("title")
        return FetchedAudio(
            path=path,
            title=title if isinstance(title, str) and title.strip() else None,
            duration_ms=int(float(duration) * 1000) if isinstance(duration, (int, float)) and duration > 0 else None,
            media_type="audio/mp4",
        )

    @staticmethod
    def _downloaded_file(info: dict, workdir: Path) -> Path:
        for download in info.get("requested_downloads") or []:
            candidate = Path(download.get("filepath") or "")
            if candidate.is_file() and workdir.resolve() in candidate.resolve().parents:
                return candidate
        files = [path for path in workdir.glob("audio.*") if path.is_file() and not path.name.endswith(".part")]
        if not files:
            raise YouTubeFailed("yt-dlp finished without an audio file.")
        return max(files, key=lambda path: path.stat().st_size)
