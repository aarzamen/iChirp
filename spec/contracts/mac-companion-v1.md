# Mac Companion v1 (HTTP API)

> Status: ACTIVE (committed with the design in plan 018; server in plan 019 lane L1, clients in plans 019 and 020).
> ADR: [ADR-014](../adr/014-mac-companion.md).

## Purpose

A small service on the owner's Mac that the iPhone reaches over the home network. It does two jobs the phone cannot
do well: **speech in the owner's local voices** (ChoiceVoice's Qwen3-TTS and Kokoro via mlx-audio) and **YouTube
audio for videos without captions** (yt-dlp). Base URL: `http://<mac-host>.local:8765` (port configurable).

## Authentication

Every request except `GET /v1/companion` carries `Authorization: Bearer <pairing token>`. The token is 32 random
bytes (base64url), generated on first start, stored at `~/Library/Application Support/ParakeetCompanion/token`
(mode 0600) and printed at start. The phone stores it in the Keychain. A wrong or missing token → `401` with
`{"error": {"code": "unauthorized", "message": "…"}}`.

Error `code`s (plan 019 server, no wire change): `unauthorized`, `bad_request`, `unknown_model`, `unknown_voice`,
`input_too_long`, `payload_too_large` (a body over 64 KB), `model_unavailable`, `encoder_unavailable` (MP3 without
ffmpeg on the Mac), `unsupported_link`, `video_unavailable`, `youtube_failed`, `youtube_timeout`,
`feature_unavailable`, `internal`. Server: [`companion/`](../../companion/README.md).

## Endpoints

### `GET /v1/companion` (no token)
```json
{"name": "Parakeet companion", "version": "1.0.0", "api": "mac-companion-v1",
 "features": {"speech": true, "youtubeAudio": true},
 "speech": {"models": ["qwen3-tts-1.7b", "kokoro-82m"], "defaultModel": "qwen3-tts-1.7b"}}
```
`features.*` is false when the dependency is missing (mlx-audio models not downloaded, yt-dlp not installed).

### `GET /v1/voices`
```json
{"voices": [{"id": "qwen3-tts-1.7b:Ryan", "name": "Ryan", "detail": "Dynamic male, strong rhythmic drive (US)",
             "languages": ["en"], "model": "qwen3-tts-1.7b", "supportsStyle": true}]}
```

### `POST /v1/audio/speech` (OpenAI speech shape)
Request: `{"model": "qwen3-tts-1.7b", "input": "<text>", "voice": "Ryan", "instructions": "<style, optional>",
"response_format": "mp3" | "wav", "language": "en" | null}`. Response: the audio bytes with `Content-Type:
audio/mpeg` or `audio/wav`. `input` is at most 4 000 characters (`413` above; counted as Unicode code points, so a Swift client
counts `unicodeScalars`). `voice` may also be a full voice id (`"qwen3-tts-1.7b:Ryan"`), and a missing `model` means
the model of that id, else `defaultModel`. Errors: `400` unknown voice or model,
`503` model not loaded (the message says which command loads it).

### `POST /v1/youtube/audio`
Request: `{"url": "https://www.youtube.com/watch?v=…"}` (youtube.com, youtu.be and m.youtube.com only; anything else
→ `400`). Response: `audio/mp4` (m4a) bytes, with headers `X-Companion-Title` (URL-encoded video title) and
`X-Companion-Duration-Ms`. Errors: `422` video unavailable / age-gated / live, `502` yt-dlp failed (its first error
line, no URL echoed), `504` over the 15-minute download limit. The server reduces the link to
`https://www.youtube.com/watch?v=<id>` first, so playlists and extra parameters never reach yt-dlp. Phone client:
`ChirpIngest.CompanionClient.youtubeAudio` (plan 019).

## Privacy rules

- The companion stores nothing it receives: text and links live only for the request; downloaded audio is streamed
  back from a temporary directory that is deleted when the response ends.
- It logs method, path, status, byte counts and durations — never text, voices' input, URLs or titles.
- It binds to the address the owner starts it with (default `0.0.0.0` on the home network) and never calls out except
  yt-dlp to YouTube and one-time model downloads from Hugging Face.
- On the phone, the companion is a `localNetwork` engine: clinical text may reach it only when the owner marked this
  Mac trusted (`PrivacyRoutingPolicy`). A YouTube link is not clinical content, but the phone still asks once per
  link before sending it off the device.

## Changes

- v1 (2026-09-22): initial.
