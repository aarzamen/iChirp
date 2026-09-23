# Plan: The Parakeet companion on the Mac (speech + YouTube audio) and finishing plan 014

> **Executor instructions:** Follow this plan step by step. Run every verification command and confirm the expected
> result before moving on. If anything in "STOP conditions" occurs, stop and report; do not improvise. When done,
> update this plan's row in [`docs/plans/README.md`](README.md) and the M5 row in
> [`spec/README.md#milestones`](../../spec/README.md#milestones).
>
> **Drift check (run first):** `git diff --stat <planned-at>..HEAD -- ChirpKit/Sources/ChirpIngest
> ChirpKit/Sources/ChirpFeatures/LinkIngestService.swift App/Sources/Screens/Capture spec/contracts/mac-companion-v1.md`.
> If the contract or the ingest API changed, refine this plan and commit before coding.

**Goal:** a companion service on the owner's Mac that serves the owner's local voices and fetches YouTube audio,
plus the phone side of YouTube audio and plan 014's remaining items.
**Architecture:** FastAPI + uvicorn in a `uv` project under `companion/`, calling mlx-audio (speech) and yt-dlp
(YouTube) in process; the phone calls it through `ChirpIngest` (YouTube) with the pairing token from the Keychain.
**Tech stack:** Python 3.12 (uv), FastAPI, mlx-audio ≥ 0.4.3, yt-dlp; Swift 6 (ChirpIngest, ChirpFeatures, App).
**Spec:** [design 018](2026-09-22-018-design-companion-voice-needle-jev.md) §1,
[mac-companion-v1](../../spec/contracts/mac-companion-v1.md), [ADR-014](../../spec/adr/014-mac-companion.md).

## Global constraints

- Repo is **public**: no keys, tokens, device ids, voice ids, personal paths beyond `~/Projects/ChoiceVoice` and
  `~/Kokoro-82M` as documented defaults, recordings or PHI. Fixtures synthetic.
- Python: always `uv` (Python 3.12 via `uv venv --python 3.12`); never a bare `pip install` into the global Python.
- The companion stores nothing it receives and logs no content (method, path, status, sizes, durations only).
- Swift 6 strict concurrency; `swift format lint --strict --recursive ChirpKit/Sources App/Sources Widgets App/Shared`
  clean; focused tests only (`swift test --package-path ChirpKit --filter <Name>`), never the full suite.
- Own simulator (`xcrun simctl create iChirp-l1 "iPhone 17 Pro"`), deleted when done; no physical iPhone.
- No new capability or entitlement; `project.yml` only for Info.plist keys if needed; commit per step, messages state
  what exists, **no assistant trailers**, no push.

## Status

- **Milestone:** M5 completion + companion
- **Effort:** M
- **Risk:** MEDIUM (a network service on the home LAN; YouTube changes)
- **Status:** IN PROGRESS (lane L1, branch `lane/companion`)

## Drift check and refinements (L1, 2026-09-22, before coding)

Drift check at `dd7fd56f`: no changes (the lane starts at the planned-at commit). Facts found while reading the
sources, and what the lane does about them:

1. **ChoiceVoice's repos are Qwen3-TTS *Base* models** (`mlx-community/Qwen3-TTS-12Hz-{1.7B,0.6B}-Base-8bit`), which
   have no preset speakers. mlx-audio 0.4.3 ignored `voice="Ryan"` on them (a seeded random voice); mlx-audio ≥ 0.5
   refuses it. Named voices (Ryan, Aiden, …) and a style instruction need the **CustomVoice** repos of the same family:
   `mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-8bit` (~3.1 GB) and `…-0.6B-CustomVoice-8bit` (~2.0 GB), both
   Apache-2.0, public, no token. The companion uses those, downloaded once into the Hugging Face cache with
   `scripts/companion.sh --download <model>`; a request never starts a download (a missing model is `503` naming that
   command). The speaker list and descriptions come from ChoiceVoice's `ui-vite/src/App.jsx` (`SPEAKERS`). The 0.6B
   model ignores style instructions, so its voices report `supportsStyle: false`.
2. **`~/Kokoro-82M` holds PyTorch weights** (`kokoro-v1_0.pth`, `voices/*.pt`) that mlx-audio cannot load. `kokoro-82m`
   is served from `~/Kokoro-82M` only if it holds MLX safetensors, else from `mlx-community/Kokoro-82M-bf16`
   (Apache-2.0, ~390 MB) after `--download kokoro-82m`, and it needs the optional `kokoro` extra (the misaki
   phonemizer). Not part of the done criteria; reported unavailable with the fixing command until then.
3. **MP3** is encoded by Homebrew `ffmpeg` (already on the Mac) in a subprocess; WAV by the standard library. Without
   ffmpeg, `response_format: "mp3"` is a `503` naming `brew install ffmpeg`.
4. **`CompanionConfiguration`** (the protocol plan 020 reads) lives in `ChirpCore` so an engine target that depends
   only on `ChirpCore` can use it; its concrete conformer is `CompanionSettingsStore` in `ChirpFeatures`.
5. youtube-transcript-api still uses ANDROID `20.10.38` (master and release v1.2.4, checked 2026-09-22), so Step 6
   keeps the value and makes the client one constant.
6. mlx-audio resolves to 0.5.5 (≥ 0.4.3, MIT).

## Live checks (L1, 2026-09-22, this Mac, companion bound to 127.0.0.1:8765, stopped afterwards)

- **Speech** (Step 2): `qwen3-tts-1.7b` (CustomVoice 8-bit, downloaded once with `--download`), voice Ryan, the
  sentence from the command above, MP3: `200`, 23.9 KB, 1.49 s of audio, played with `afplay`. **First request
  16.9 s, of which the model load was 13.9 s**; the second request (WAV, with a style instruction) took 0.49 s.
  `GET /v1/voices` without the token: `401`; with it: nine voices. The log held only method, path, status, sizes,
  times, the model id and the character count.
- **YouTube** (Step 3): "Caminandes 3: Llamigos" (Blender Foundation, CC BY), 150 s, via a `youtu.be` link: `200`,
  2.4 MB `audio/mp4` (AAC, 150.1 s) in 2.0 s, `X-Companion-Title` and `X-Companion-Duration-Ms: 150000` correct, the
  temporary folder gone afterwards, neither the link nor the title in the log.

## Current state

- Contract `spec/contracts/mac-companion-v1.md` is committed. No `companion/` folder exists.
- `ChirpIngest` has `LinkClassifier`, `MediaDownloader`, `PodcastEpisodeResolver`, `YouTubeCaptionFetcher`,
  `IngestHTTPClient`; `LinkIngestService` (ChirpFeatures) imports captions or fails with "no captions".
- ChoiceVoice (`~/Projects/ChoiceVoice/sidecar`, uv, mlx-audio 0.4.3) runs Qwen3-TTS (0.6B/1.7B, speakers such as
  Ryan, a style instruction); `~/Kokoro-82M` holds Kokoro-82M. mlx-audio's server exposes `POST /v1/audio/speech`.
- M5 lane concerns: downloads of unknown size show "0%"; the YouTube ANDROID client version `20.10.38` may be stale;
  podcasts and captions were never run against the live services.

## Commands you will need

| Purpose | Command | Expected |
|---|---|---|
| Companion tests | `cd companion && uv run pytest -q` | all pass, no network |
| Run the companion | `scripts/companion.sh` | prints URL + pairing token |
| Live companion check | `curl -s localhost:8765/v1/companion` | JSON with `features` |
| Focused Swift tests | `swift test --package-path ChirpKit --filter ChirpIngestTests` | green |
| Live ingest tests (opt-in) | `CHIRP_LIVE_NETWORK_TESTS=1 swift test --package-path ChirpKit --filter LiveIngestTests` | green or skipped with a reason |

## Scope

- **In:** `companion/**` (new), `scripts/companion.sh` (new), `ChirpKit/Sources/ChirpIngest/**` (a
  `CompanionClient`), `LinkIngestService.swift` (YouTube audio path), the Paste-a-link sheet's no-captions branch,
  Settings → Mac companion (host, port, pairing token, trusted), tests, `spec/11-ingest.md`, `spec/12-privacy.md`
  network-surfaces rows, `docs/human-qa-guide.md`, AGENTS.md command table (one row for `scripts/companion.sh`).
- **Out:** speech on the phone (plan 020 builds `CompanionVoice` against the same contract); Needle; Jev.
- **Must not change:** captions-first behavior; the media layout (additive only); existing migrations.

## Steps

### Step 1: Companion skeleton, auth and health
`companion/pyproject.toml` (name `parakeet-companion`, Python ≥ 3.12, deps fastapi, uvicorn, mlx-audio, yt-dlp;
dev dep pytest, httpx), `companion/parakeet_companion/{app.py,auth.py,config.py,__main__.py}`. Token: 32 random bytes
base64url in `~/Library/Application Support/ParakeetCompanion/token` (0600), created on first start, printed at
start; `--host` (default `0.0.0.0`), `--port` (default 8765). `GET /v1/companion` unauthenticated; everything else
requires `Authorization: Bearer <token>`. Logging middleware: method, path, status, bytes, ms — nothing else.
**Verify:** pytest with FastAPI's TestClient: health without token 200; `/v1/voices` without/with wrong token 401;
a log capture proves request bodies never appear.

### Step 2: Speech (mlx-audio)
`POST /v1/audio/speech` and `GET /v1/voices` per the contract. Models: `qwen3-tts-1.7b`, `qwen3-tts-0.6b` (the same
Hugging Face repos ChoiceVoice uses — read `~/Projects/ChoiceVoice/sidecar` for the ids and speaker list),
`kokoro-82m` (local path `~/Kokoro-82M` if present). Load lazily, keep one model resident, serialize synthesis with
one lock. Style → Qwen3-TTS instruction. Limits: 4 000 characters (413). Missing model → 503 with the command that
fixes it. Inject the synthesizer behind a protocol so tests use a fake that returns a tiny WAV.
**Verify:** pytest with the fake (shape, limits, errors, content types); a manual live check on the Mac:
`curl -H "Authorization: Bearer $TOKEN" -d '{"model":"qwen3-tts-1.7b","input":"Hello from Parakeet.","voice":"Ryan"}' -o /tmp/p.mp3 localhost:8765/v1/audio/speech && afplay /tmp/p.mp3`
— record the result (and first-load time) in the plan.

### Step 3: YouTube audio (yt-dlp)
`POST /v1/youtube/audio`: allowlist youtube.com / youtu.be / m.youtube.com; yt-dlp Python API, `bestaudio[ext=m4a]`,
no playlists, 15-minute wall limit, a `TemporaryDirectory` deleted when the streamed response ends; headers
`X-Companion-Title` (URL-encoded) and `X-Companion-Duration-Ms`. Errors 400/422/502/504 per the contract, never
echoing the URL. yt-dlp behind a protocol; tests use a fake.
**Verify:** pytest with the fake (allowlist, limits, cleanup of the temp dir, headers); one manual live run on a
short public Creative Commons video, recorded in the plan (title and duration only).

### Step 4: `scripts/companion.sh` and docs
`uv run --project companion parakeet-companion "$@"`; prints the LAN URL (`$(scutil --get LocalHostName).local`) and
the token. Add the AGENTS.md command row, a `companion/README.md` (start, pair, trust, stop; what it logs; what it
never stores), `THIRD_PARTY_LICENSES.md` rows (FastAPI MIT, uvicorn BSD-3, yt-dlp Unlicense, mlx-audio MIT).

### Step 5: Phone side — Mac companion settings and YouTube audio
- `ChirpIngest/CompanionClient.swift`: health, voices (for plan 020 to reuse), `youtubeAudio(url:) async throws ->
  (fileURL, title, durationMs)` (streams to a file under the item's media folder), Bearer token, refuses redirects,
  errors mapped to sentences.
- Settings → **Mac companion** (new file): host (`name.local` or IP), port, pairing token (Keychain via
  `ChirpKeychain`), **Trusted for clinical text** toggle (feeds `PrivacyRoutingPolicy.trustedLocalNetworkHosts`),
  Test connection (shows features and version). One companion configuration; plan 020 reads it.
- `LinkIngestService`: when a YouTube video has no captions and a companion is configured, offer "Get the audio from
  your Mac" (confirm once per link: the link leaves the phone for your Mac), then download → normal transcription
  with `sourceType: .url`, `sourceURL` and the companion's title. Without a companion: today's message plus "Set up
  the Mac companion in Settings".
- `Info.plist`: `NSLocalNetworkUsageDescription` already exists (M4); extend its text to mention the companion.
**Verify:** focused tests with a URLProtocol stub for `CompanionClient` and the service's no-captions branch;
simulator screenshots of Settings → Mac companion and the Paste-a-link no-captions offer.

### Step 6: Plan 014 open items
- Unknown-size downloads show an indeterminate "Downloading…" (not "0%"); test it.
- Update the YouTube ANDROID client version to the current one used by youtube-transcript-api (check its source)
  and make it a single constant.
- `LiveIngestTests` (opt-in `CHIRP_LIVE_NETWORK_TESTS=1`): resolve one public Apple Podcasts episode link and fetch
  captions for one public captioned video; skipped by default with a reason. Run them once from the Mac and record
  the outcome in plan 014.
- Record the YouTube decision in plan 014 (owner, 2026-09-22: companion yt-dlp; App Review irrelevant).

## Test plan

pytest for every companion endpoint with fakes (no network, no models); Swift focused tests for `CompanionClient`,
the no-captions branch and the download progress state; the opt-in live tests; the two manual live checks (speech,
YouTube) recorded in the plan.

## Done criteria

- [ ] `scripts/companion.sh` starts the companion; `/v1/companion` reports speech and youtubeAudio.
- [ ] A Qwen3-TTS voice speaks through `/v1/audio/speech` on the Mac (manual check recorded).
- [ ] A captionless YouTube link becomes a transcript through the companion (simulator against the live companion).
- [ ] Pytest and focused Swift tests green; lint clean; docs and licenses updated; plan 014 decision recorded.
- [ ] Everything committed; nothing pushed.

## STOP conditions

- Anything would store or log text, links or titles on the Mac.
- An endpoint would work without the pairing token (other than health).
- A dependency is GPL-incompatible or needs a paid account.
- A model download needs more than the Hugging Face cache (for example an account token).
