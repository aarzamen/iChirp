"""`parakeet-companion`: starts the companion, or downloads a speech model once (`--download <model>`)."""

from __future__ import annotations

import argparse
import importlib.util
import logging
import socket
import subprocess
import sys

from . import config
from .app import LOGGER_NAME, create_app
from .auth import TokenFileError, load_or_create_token
from .backends import SpeechBackend, YouTubeBackend
from .config import CompanionSettings


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="parakeet-companion",
        description="Serves your local voices and YouTube audio to Parakeet on your iPhone (mac-companion-v1).",
    )
    parser.add_argument("--host", default=config.DEFAULT_HOST, help="address to listen on (default 0.0.0.0)")
    parser.add_argument("--port", type=int, default=config.DEFAULT_PORT, help="port (default 8765)")
    parser.add_argument(
        "--advertise-host",
        default=None,
        help="the name the iPhone should use, e.g. my-mac.local (default: this Mac's local host name)",
    )
    parser.add_argument("--download", metavar="MODEL", help="download a speech model into the Hugging Face cache, then exit")
    parser.add_argument("--list-models", action="store_true", help="list the speech models and whether each is ready")
    args = parser.parse_args(argv)

    _configure_logging()
    speech, youtube = build_backends()

    if args.download:
        return _download(speech, args.download)
    if args.list_models:
        _print_models(speech)
        return 0

    try:
        token, created = load_or_create_token(config.token_path())
    except TokenFileError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1

    settings = CompanionSettings(token=token)
    app = create_app(settings, speech=speech, youtube=youtube)
    host_name = args.advertise_host or _local_host_name()
    _print_banner(args.host, args.port, host_name, token, created, speech, youtube)

    import uvicorn

    uvicorn.run(
        app,
        host=args.host,
        port=args.port,
        access_log=False,  # uvicorn's access log prints full request lines; ours prints no content
        log_level="warning",
        server_header=False,
        date_header=False,
    )
    return 0


def build_backends() -> tuple[SpeechBackend | None, YouTubeBackend | None]:
    """The real backends when their runtimes are installed; None otherwise (the health endpoint reports false)."""
    speech: SpeechBackend | None = None
    youtube: YouTubeBackend | None = None
    try:
        from .speech import MLXSpeech

        speech = MLXSpeech()
    except ImportError:
        speech = None
    try:
        from .youtube import YtDlpBackend

        youtube = YtDlpBackend() if importlib.util.find_spec("yt_dlp") is not None else None
    except ImportError:
        youtube = None
    return speech, youtube


def _configure_logging() -> None:
    handler = logging.StreamHandler(sys.stderr)
    handler.setFormatter(logging.Formatter("%(asctime)s %(levelname)s %(message)s"))
    logger = logging.getLogger(LOGGER_NAME)
    logger.handlers[:] = [handler]
    logger.setLevel(logging.INFO)
    logger.propagate = False


def _local_host_name() -> str:
    try:
        name = subprocess.run(
            ["scutil", "--get", "LocalHostName"], capture_output=True, text=True, timeout=5, check=True
        ).stdout.strip()
        if name:
            return f"{name}.local"
    except (OSError, subprocess.SubprocessError):
        pass
    return socket.gethostname()


def _print_models(speech: SpeechBackend | None) -> None:
    if speech is None:
        print("Speech: mlx-audio is not installed. Run: uv sync --project companion")
        return
    for model in speech.models():
        state = "ready" if model.available else f"not ready — {model.reason}"
        print(f"  {model.id}: {state}")


def _download(speech: SpeechBackend | None, model_id: str) -> int:
    download = getattr(speech, "download", None)
    if download is None:
        print("error: speech is not installed. Run: uv sync --project companion", file=sys.stderr)
        return 1
    try:
        download(model_id)
    except Exception as error:  # noqa: BLE001 — a CLI; show the reason and exit non-zero
        print(f"error: {error}", file=sys.stderr)
        return 1
    print(f"{model_id} is downloaded.")
    return 0


def _print_banner(
    bind_host: str,
    port: int,
    host_name: str,
    token: str,
    created: bool,
    speech: SpeechBackend | None,
    youtube: YouTubeBackend | None,
) -> None:
    lines = [
        f"{config.NAME} {config.VERSION} ({config.API})",
        f"  Listening on {bind_host}:{port}",
        "",
        "  On your iPhone: Settings → Mac companion",
        f"    Host:          {host_name}",
        f"    Port:          {port}",
        f"    Pairing token: {token}" + ("   (new)" if created else ""),
        f"    (kept in {config.token_path()}, readable only by you)",
        "",
    ]
    if speech is None:
        lines.append("  Speech: not installed (run: uv sync --project companion)")
    else:
        for model in speech.models():
            lines.append(f"  Speech {model.id}: " + ("ready" if model.available else f"not ready — {model.reason}"))
    lines.append("  YouTube audio: " + ("ready" if youtube is not None and youtube.is_available() else "not installed"))
    lines.append("")
    lines.append("  Nothing you send is stored; the log shows only sizes and timings. Stop with Control-C.")
    print("\n".join(lines), flush=True)


if __name__ == "__main__":
    raise SystemExit(main())
