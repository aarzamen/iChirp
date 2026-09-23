"""The HTTP API (spec/contracts/mac-companion-v1.md).

Every request except `GET /v1/companion` needs `Authorization: Bearer <pairing token>`; the guard runs before any
route, so a new route cannot forget it. The request log carries method, a known path (else "other"), status, byte
counts and milliseconds, and nothing else: never text, voices' input, links or titles.
"""

from __future__ import annotations

import json
import logging
import time
from typing import Literal

from fastapi import FastAPI
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse, Response
from pydantic import BaseModel, ConfigDict, Field
from starlette.datastructures import Headers
from starlette.exceptions import HTTPException as StarletteHTTPException
from starlette.types import ASGIApp, Message, Receive, Scope, Send

from . import config
from .auth import is_authorized
from .backends import SpeechBackend, SpeechJob, YouTubeBackend
from .config import CompanionSettings
from .errors import BadRequest, CompanionError, FeatureUnavailable, InputTooLong, error_body

LOGGER_NAME = "parakeet_companion"
_METHODS = frozenset({"GET", "POST", "HEAD", "PUT", "PATCH", "DELETE", "OPTIONS"})
_STATUS_CODES = {
    400: "bad_request",
    401: "unauthorized",
    404: "not_found",
    405: "method_not_allowed",
    413: "payload_too_large",
}
_STATUS_MESSAGES = {
    404: "There is no such endpoint on the Parakeet companion.",
    405: "That method is not allowed on this endpoint.",
    413: "The request is too large.",
}


def create_app(
    settings: CompanionSettings,
    speech: SpeechBackend | None = None,
    youtube: YouTubeBackend | None = None,
    logger: logging.Logger | None = None,
) -> FastAPI:
    """Builds the companion. `speech` / `youtube` are None when their runtime is not installed (features false)."""
    log = logger or logging.getLogger(LOGGER_NAME)
    app = FastAPI(title=config.NAME, version=config.VERSION, docs_url=None, redoc_url=None, openapi_url=None)
    app.state.settings = settings
    app.state.speech = speech
    app.state.youtube = youtube

    @app.exception_handler(CompanionError)
    async def companion_error(_request, error: CompanionError) -> JSONResponse:
        return JSONResponse(error_body(error.code, error.message), status_code=error.status)

    @app.exception_handler(StarletteHTTPException)
    async def http_error(_request, error: StarletteHTTPException) -> JSONResponse:
        code = _STATUS_CODES.get(error.status_code, "http_error")
        message = _STATUS_MESSAGES.get(error.status_code, "The request could not be handled.")
        return JSONResponse(error_body(code, message), status_code=error.status_code)

    @app.exception_handler(RequestValidationError)
    async def validation_error(_request, error: RequestValidationError) -> JSONResponse:
        # Field names only; never the values the request carried.
        fields = sorted({str(item.get("loc", ("",))[-1]) for item in error.errors() if item.get("loc")})
        detail = f" Check: {', '.join(fields)}." if fields else ""
        return JSONResponse(
            error_body("bad_request", "The request body is not what this endpoint expects." + detail),
            status_code=400,
        )

    @app.get(config.HEALTH_PATH)
    def companion_health() -> dict:
        return health(speech, youtube)

    @app.get(config.VOICES_PATH)
    def list_voices() -> dict:
        if speech is None:
            raise FeatureUnavailable("Speech is not installed in this companion. Run `uv sync --project companion`.")
        return {"voices": [voice.as_json() for voice in speech.voices()]}

    @app.post(config.SPEECH_PATH)
    def speak(request: SpeechRequest) -> Response:
        if speech is None:
            raise FeatureUnavailable("Speech is not installed in this companion. Run `uv sync --project companion`.")
        if len(request.input) > settings.max_input_characters:
            raise InputTooLong(
                f"The text is longer than {settings.max_input_characters} characters. Send it in shorter pieces."
            )
        if not request.input.strip():
            raise BadRequest("There is no text to speak.")
        if not request.voice.strip():
            raise BadRequest("Choose a voice. GET /v1/voices lists them.")
        job = SpeechJob(
            model=(request.model or "").strip(),
            text=request.input,
            voice=request.voice.strip(),
            instructions=(request.instructions or "").strip() or None,
            language=(request.language or "").strip() or None,
            response_format=request.response_format,
        )
        result = speech.synthesize(job)
        return Response(content=result.data, media_type=result.media_type)

    app.add_middleware(GuardAndLog, settings=settings, logger=log)
    return app


class SpeechRequest(BaseModel):
    """`POST /v1/audio/speech` (OpenAI speech shape). Unknown fields such as `speed` are ignored."""

    model_config = ConfigDict(extra="ignore")

    model: str | None = Field(default=None, max_length=64)
    input: str
    voice: str = Field(max_length=128)
    instructions: str | None = Field(default=None, max_length=1_000)
    response_format: Literal["mp3", "wav"] = "mp3"
    language: str | None = Field(default=None, max_length=16)


def health(speech: SpeechBackend | None, youtube: YouTubeBackend | None) -> dict:
    """`GET /v1/companion`: what this companion can do right now. Loads no model and makes no network call."""
    available = [model.id for model in speech.models() if model.available] if speech is not None else []
    default = "qwen3-tts-1.7b" if "qwen3-tts-1.7b" in available else (available[0] if available else None)
    return {
        "name": config.NAME,
        "version": config.VERSION,
        "api": config.API,
        "features": {
            "speech": bool(available),
            "youtubeAudio": youtube is not None and youtube.is_available(),
        },
        "speech": {"models": available, "defaultModel": default},
    }


class _BodyTooLarge(StarletteHTTPException):
    def __init__(self) -> None:
        super().__init__(status_code=413)


class GuardAndLog:
    """Outermost app middleware: the pairing-token check, the body-size limit and the content-free request log."""

    def __init__(self, app: ASGIApp, settings: CompanionSettings, logger: logging.Logger) -> None:
        self.app = app
        self.settings = settings
        self.logger = logger

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return
        started = time.perf_counter()
        method = scope.get("method", "")
        path = scope.get("path", "")
        headers = Headers(scope=scope)
        state = {"status": 0, "sent": 0, "received": 0, "started": False}
        limit = self.settings.max_body_bytes

        async def send_logged(message: Message) -> None:
            if message["type"] == "http.response.start":
                state["status"] = message["status"]
                state["started"] = True
            elif message["type"] == "http.response.body":
                state["sent"] += len(message.get("body", b""))
            await send(message)

        async def receive_limited() -> Message:
            message = await receive()
            if message["type"] == "http.request":
                state["received"] += len(message.get("body", b""))
                if state["received"] > limit:
                    raise _BodyTooLarge()
            return message

        try:
            is_public = method in ("GET", "HEAD") and path == config.HEALTH_PATH
            if not is_public and not is_authorized(headers.get("authorization"), self.settings.token):
                await _send_error(
                    send_logged, 401, "unauthorized",
                    "The pairing token is missing or wrong. Copy it from the Mac where the companion runs.",
                )
            elif _declared_length(headers) > limit:
                await _send_error(send_logged, 413, "payload_too_large", "The request is too large.")
            else:
                await self.app(scope, receive_limited, send_logged)
        except Exception as error:  # noqa: BLE001 — never let a message with content reach uvicorn's log
            self.logger.error("request_failed error_type=%s", type(error).__name__)
            if not state["started"]:
                await _send_error(send_logged, 500, "internal", "The companion hit an internal error. Try again.")
        finally:
            self.logger.info(
                "request method=%s path=%s status=%d bytes_in=%d bytes_out=%d ms=%d",
                method if method in _METHODS else "OTHER",
                path if path in config.KNOWN_PATHS else "other",
                state["status"],
                state["received"],
                state["sent"],
                int((time.perf_counter() - started) * 1000),
            )


def _declared_length(headers: Headers) -> int:
    try:
        return int(headers.get("content-length") or 0)
    except ValueError:
        return 0


async def _send_error(send: Send, status: int, code: str, message: str) -> None:
    body = json.dumps(error_body(code, message)).encode("utf-8")
    await send(
        {
            "type": "http.response.start",
            "status": status,
            "headers": [(b"content-type", b"application/json"), (b"content-length", str(len(body)).encode())],
        }
    )
    await send({"type": "http.response.body", "body": body})
