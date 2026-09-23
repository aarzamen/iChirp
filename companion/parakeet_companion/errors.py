"""Errors the companion answers with: `{"error": {"code": "...", "message": "..."}}` (mac-companion-v1).

Messages are written for the person reading them on the phone. They never contain the text, voice input, link or
title a request carried.
"""

from __future__ import annotations


class CompanionError(Exception):
    status = 500
    code = "internal"

    def __init__(self, message: str) -> None:
        super().__init__(message)
        self.message = message


class Unauthorized(CompanionError):
    status = 401
    code = "unauthorized"


class BadRequest(CompanionError):
    status = 400
    code = "bad_request"


class UnknownModel(CompanionError):
    status = 400
    code = "unknown_model"


class UnknownVoice(CompanionError):
    status = 400
    code = "unknown_voice"


class InputTooLong(CompanionError):
    status = 413
    code = "input_too_long"


class BodyTooLarge(CompanionError):
    status = 413
    code = "payload_too_large"


class ModelUnavailable(CompanionError):
    """The model is not downloaded or its runtime is missing; the message names the command that fixes it."""

    status = 503
    code = "model_unavailable"


class EncoderUnavailable(CompanionError):
    status = 503
    code = "encoder_unavailable"


class SynthesisFailed(CompanionError):
    status = 500
    code = "synthesis_failed"


class UnsupportedLink(CompanionError):
    status = 400
    code = "unsupported_link"


class VideoUnavailable(CompanionError):
    """Unavailable, private, age-gated or live."""

    status = 422
    code = "video_unavailable"


class YouTubeFailed(CompanionError):
    status = 502
    code = "youtube_failed"


class YouTubeTimedOut(CompanionError):
    status = 504
    code = "youtube_timeout"


class FeatureUnavailable(CompanionError):
    status = 503
    code = "feature_unavailable"


def error_body(code: str, message: str) -> dict:
    return {"error": {"code": code, "message": message}}
