# Design: Mac companion, voice output, Needle 3 and Jev

> **Status: APPROVED** by the owner, 2026-09-22 ("Approved, go"). Governs plans
> [019](2026-09-22-019-mac-companion-and-m5-finish.md), [020](2026-09-22-020-voice-output.md),
> [015](2026-09-22-015-m6-structure-models.md) (Needle) and [021](2026-09-22-021-m6a-jev-decision-trial.md) (Jev, the owner's own plan).
> Planned at `5cf6aa86` + the contract commit that adds this file.

## What the owner asked for

1. Finish plan 014 (M5 ingest): its open items, including YouTube audio.
2. A Jev spec, informed by the owner's Needle Bench design (`docs/research/2026-09-22-needle-bench-spec.md`) and the
   Cactus/Needle/Jev research (`docs/research/2026-09-22-cactus-needle-jev.md`): show how these structure and
   decision models serve transcription.
3. Text-to-speech ("text voice") that involves the owner's two voice projects: **ChoiceVoice** (local Qwen3-TTS on
   the Mac via mlx-audio, `~/Projects/ChoiceVoice`) and the Grok/xAI voice path (**Voice-actor**; its code is not on
   GitHub or this Mac, but the owner's **Readback** app at `~/readback` has the working Swift `XAIProvider`).

Owner decisions (2026-09-22): plan 014 = finish its open items; Needle demos = **SOAP fields and medications** and
**dictation voice commands** (not the MARCH card); voices = **ChoiceVoice on the Mac** and **Grok (xAI)**, no Apple
voices; Parakeet is never submitted to the App Store, so App Review is not a constraint.

## Verified facts this design rests on

- **needle-rs** (github.com/Geekgineer/needle-rs, **MIT**, v0.3.1) is a source runtime for Needle 1/2/3 with a C FFI
  crate (`crates/needle-c`, `include/needle.h`, `needle_v3_*`: one `.cact` container, constrained decoding, a
  confidence probe, 8192-token context; `"[]"` means a deliberate abstention). Rust 1.87+ is installed on the Mac.
- **Needle 3 weights**: Hugging Face `Cactus-Compute/needle3`, **Apache-2.0**, 8–29 MB `.cact`.
- **Laya** (`convaiinnovations/laya`, Apache-2.0, 421M, ModernBERT-large): the open, local "Jev-class" model.
- **Jev** (TypeSafe AI): cloud only, `POST https://api.typesafe.ai/v1/systemone`, Choice / Score / Noul questions
  with calibrated probabilities; no weights, no on-prem. MacParakeet already ships a working client
  (`upstream/macparakeet/Sources/MacParakeetCore/Services/VoiceControl/JevDecisionClient.swift`, model `jev-1.13.0`).
- **xAI TTS**: `POST https://api.x.ai/v1/tts` (Bearer key; voices ara, eve, leo, rex, sal; mp3), `GET
  /v1/api-key` validates a key — as implemented in Readback `Sources/TTS/XAIProvider.swift`.
- **mlx-audio 0.4.3** (ChoiceVoice's runtime) ships a FastAPI server with OpenAI-style `POST /v1/audio/speech`,
  `GET/POST /v1/models`; it runs Qwen3-TTS (0.6B/1.7B; preset speakers such as Ryan; a style instruction) and
  Kokoro-82M (`~/Kokoro-82M`).

## Architecture

```
iPhone (Parakeet)                                   Owner's Mac (trusted, same Wi-Fi)
─────────────────                                   ─────────────────────────────────
ChirpEngineVoiceHTTP ── OpenAI speech ────────────▶ Parakeet companion (companion/, uv, Python)
  • CompanionVoice (localNetwork)                     • POST /v1/audio/speech → mlx-audio (Qwen3-TTS, Kokoro)
  • XAIVoice (cloud) ─────────────▶ api.x.ai          • POST /v1/youtube/audio → yt-dlp → m4a
ChirpIngest YouTube (no captions) ── /v1/youtube ─▶   • GET  /v1/companion (health, features, voices)
ChirpEngineNeedle (needle-rs, on device)              • pairing token (Bearer), shown on the Mac
ChirpEngineJev (cloud) ──────────▶ api.typesafe.ai
```

Every text or link that leaves the phone goes through the routing rules: `PrivacyRoutingPolicy` for voices (clinical
→ trusted companion allowed; cloud needs a per-run confirmation) and plan 021's stricter rule for Jev (clinical items
are never sent, override or not). Needle runs on the phone, so clinical text may use it.

### 1. The Parakeet companion (plan 019, lane L1)

A small FastAPI service in `companion/` (uv project, Python 3.12, depends on `mlx-audio` and `yt-dlp`), started on the
Mac with `scripts/companion.sh` (`uv run --project companion parakeet-companion --host 0.0.0.0`). Contract:
[`spec/contracts/mac-companion-v1.md`](../../spec/contracts/mac-companion-v1.md). It reuses model weights already in
the Hugging Face cache (ChoiceVoice's Qwen3-TTS) and `~/Kokoro-82M`. It stores nothing it is sent: text and links are
held in memory for one request; audio files are streamed back and deleted. Pairing: a random token printed at start
(and persisted in `~/Library/Application Support/ParakeetCompanion/token`, 0600); the phone stores it in the Keychain
and sends `Authorization: Bearer <token>`. ADR-014 records it.

Plan 014's open items ride in the same lane: YouTube audio via the companion when captions are missing (the phone
asks before sending a link off-device), opt-in live-network tests for podcasts and captions (run from the Mac), an
indeterminate "Downloading…" state when the size is unknown, and a current YouTube client version.

### 2. Voice output (plan 020, lane L2)

New engine kind `speechSynthesis`, contract
[`speech-synthesis-plugin-v1.md`](../../spec/contracts/speech-synthesis-plugin-v1.md) (`SpeechSynthesizing` in
`ChirpCore`, committed with this design). One plug-in target, `ChirpEngineVoiceHTTP`, ported from Readback
(`TTSProvider`, `XAIProvider`, `OpenAIProvider`, `Chunker`, `SynthQueue`, `PlaybackEngine` semantics; provenance
header "Ported from Readback (owner's project)"):

- `CompanionVoice`: OpenAI speech format to the companion; voices from `GET /v1/companion`; locality `localNetwork`.
- `XAIVoice`: `api.x.ai/v1/tts`; stock voices plus a free-text **Voice ID** field for the owner's cloned voice (the
  id is typed on the phone and never committed — the repo is public); locality `cloud`.

A `VoicePlayer` in `ChirpFeatures` chunks text, synthesizes ahead one chunk, and plays through M2's
`AudioSessionController` (playback yields to recording). Surfaces: **Listen** on deliverables and transcripts, spoken
Ask answers (toggle), and the dictation voice command "read back" (lane L3 calls `VoicePlayer`). Settings → Voices:
providers, voice picker, style (companion), Test voice. Audio is cached in `tmp/speech-<hash>/` only (never in the
database); nothing is logged but ids and error kinds. No Apple voices (owner's choice): with neither provider
reachable, Listen says so.

### 3. Needle 3 on device (plan 015 revised, lane L3)

`scripts/build_needle.sh` clones needle-rs at a pinned commit into gitignored `vendor/needle-rs`, builds `needle-c` as
a static library for `aarch64-apple-ios`, `aarch64-apple-ios-sim` and `aarch64-apple-darwin`, and packages
`vendor/NeedleC.xcframework` (+ header, module map). `ChirpKit/Package.swift` adds target `ChirpEngineNeedle` (a
binary target plus a Swift wrapper) **only when that XCFramework exists**; otherwise the app shows "Needle is not in
this build — run scripts/build_needle.sh". CI installs the Rust iOS targets and runs the script, so CI covers it.
`needle3.cact` downloads on demand from Hugging Face (Apache-2.0) into Application Support, like Parakeet; its SHA-256
is recorded with every result. **ADR-012**: built from MIT source with Apache-2.0 weights, Needle needs no ADR-010
gate; the gate still applies to Cactus's own engine and the binary-only `libneedle.a`.

Ported from Needle Bench: a **deterministic numeric normalizer** (doses with units, vitals, times, frequencies,
laterality → tags; the model copies tags, code maps them back; "25 minute" must never become seconds), **frozen tool
catalogs** (`soap-meds.v1`, `dictation-commands.v1`), **confidence gating** (act ≥ 0.85, provisional ≥ 0.60, else
"needs review" → escalate to the on-device Apple model or ask the user; thresholds are settings), an **evidence
ledger** (every field cites its transcript span; tap → seek the audio via word timestamps), a rule-based **STUB**
engine (always available, always labelled STUB), synthetic **eval cases** with an in-app Eval view (tool-shape
accuracy, argument accuracy, numeric hard-fail count) and **export** (JSON + "Copy for LLM" Markdown).

Demos: (1) **SOAP fields and medications** — vitals, drugs, dose + unit, route, frequency, allergies, plan items from
a dictated clinical note into a typed draft that the SOAP template consumes; clinical, so on device only; always a
draft for review. (2) **Dictation voice commands** — at most 10 tools: `new_paragraph`, `new_line`, `bullet_list`,
`scratch_that`, `undo`, `capitalize`, `read_back`, `send_to_soap`, `send_to_transform`, `stop`; commands are only
recognized in a short trailing window after a pause, so dictated text is never eaten.

### 4. Jev (plan 021, lane L4 — the owner's plan)

The owner supplied the Jev plan themselves ([plan 021](2026-09-22-021-m6a-jev-decision-trial.md), "M6a — Jev
decision-model trial"); it supersedes the controller's draft Jev section. In short: a `DecisionModel` contract in
`ChirpCore` (choice questions only in v1, reusing `LanguageModelError`/`LanguageModelAvailability`), a `ChirpEngineJev`
target ported from MacParakeet's working `JevDecisionClient.swift` (the real `systemone` wire protocol and its answer
validation), a `DecisionService` with three recipes — **classify the recording**, **suggest a template**, **tag
paragraphs** — a gate (act ≥ 0.80, suggest ≥ 0.55, set later from a calibration table), results as suggestions only,
a Settings → Models "Decision models" section, a Jev menu on the Transcript screen, a QA stub server, and a gated live
evaluation on 80 synthetic cases that produces accuracy, calibration, latency and cost numbers. **Clinical items never
reach Jev, override or not.** It writes ADR-013 and `spec/contracts/decision-model-plugin-v1.md` itself.

Follow-ups from the controller's draft, not in plan 021: a prompt-injection guard before cloud language-model runs
(yes/no), deliverable completeness scores (score), a Jev-routed Ask cascade, and on-device stand-ins (Needle, Laya)
for clinical items.

## Lanes, order and rules

Step 0 (controller, done with this design): the speech and companion contracts, `SpeechSynthesizing`, ADR-012 and
ADR-014, plans 019 and 020, the 015 revision, and the owner's plan 021 (which writes its own contract and ADR-013). Then four lanes in parallel worktrees from that commit: **L1** companion +
014, **L2** voices, **L3** Needle, **L4** Jev + Laya. Merge order L1 → L2 → L4 → L3; full gate
(`scripts/test.sh`) and `scripts/scan_secrets.sh` after each merge; at the end, install and `device_smoke.sh` on both
phones. Every lane: its own simulator; new code in new files, additive edits to shared ones; the repo is public (no
keys, voice ids, device ids, PHI); no physical-device installs by lanes; no push; no assistant trailers.

Migrations: L3 `v7-structured-results` (extractions, ledger rows, eval runs); L4 adds none (a `decision` feature value
in the existing `llm_runs` ledger); L1 and L2 add none.
