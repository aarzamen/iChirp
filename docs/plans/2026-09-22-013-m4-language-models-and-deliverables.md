# Plan: M4 — Language models and deliverables (summaries, meeting notes, agendas, SOAP notes, Transforms, Ask)

> **Executor instructions:** Follow this plan step by step. Run every verification command and confirm the expected
> result before moving on. If anything in "STOP conditions" occurs, stop and report; do not improvise. When done,
> update this plan's row in [`docs/plans/README.md`](README.md) and the M4 row in
> [`spec/README.md#milestones`](../../spec/README.md#milestones).
>
> **Drift check (run first):** written at `bd8cfc7c`, before M1 code existed.
> 1. `grep -n "^| \[003\]" docs/plans/README.md` → must be **IMPLEMENTED**. If not, STOP.
> 2. `git diff --stat bd8cfc7c..HEAD -- ChirpKit/Sources/ChirpCore/Engines ChirpKit/Sources/ChirpStore ChirpKit/Sources/ChirpFeatures App/Sources`,
>    then confirm the "Current state" contracts. Refine and commit before coding; STOP if the approach changes.

## Status

- **Milestone:** M4
- **Priority:** P0 for the end goal (deliverables are what the owner hands to others)
- **Effort:** L
- **Risk:** HIGH (privacy routing of clinical text, keys, long-context behavior)
- **Depends on:** plan 003 IMPLEMENTED (M2 recommended first so "Polish after" and Transforms meet cleanly)
- **Governing docs:** [spec/08](../../spec/08-language-and-structure-models.md), [spec/12](../../spec/12-privacy.md),
  [ADR-002](../../spec/adr/002-local-first-and-privacy-classes.md), [ADR-004](../../spec/adr/004-engine-plugin-architecture.md),
  [design handoff: Ask and Transform](2026-09-22-001-feat-iphone-app-design-handoff.md)
- **Planned at:** commit `bd8cfc7c`, 2026-09-22
- **Status:** NOT STARTED

## Why this matters

The end goal is not transcripts; it is documents: meeting notes, agendas, SOAP notes, polished text. This milestone
turns any transcript into those deliverables with the owner's choice of model (on device, the owner's Mac over the LAN, or a
cloud provider) while guaranteeing that clinical text never leaves the phone without their explicit per-run consent.

## Current state (expected after M1)

- `ChirpCore`: `LanguageModel` (`generate(_:) -> AsyncThrowingStream<GenerationEvent, Error>`), `GenerationRequest`
  (with `privacyClass`), `PrivacyRoutingPolicy.allows(_:for:host:userOverride:)`, `EngineDescriptor` with locality.
  No conformers.
- `Transcription.privacyClass` persisted (default `personal`); no UI to change it yet.
- App placeholders: Ask tab, Transform button, Transforms tab items, Settings "Cloud models" (all "Milestone M4").
- Upstream to port (pipeline map §6): `Services/LLM/` (`LLMClient` adapters: Anthropic Messages, OpenAI-compatible,
  Ollama native `/api/chat`; SSE streaming over `URLSession.AsyncBytes`), `LLMConfigStore` + `KeychainKeyValueStore`
  (keys in the Keychain), `Models/Prompt.swift` built-ins, `PromptTemplateRenderer` (`{{transcript}}`,
  `{{userNotes}}`), `InProcessLLMClient` map-reduce (chunk 12K characters, threshold 24K), the metadata-only
  `llm_runs` ledger.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Focused tests | `scripts/check.sh <Filter>` | green, lint clean |
| Full package suite (once) | `swift test --package-path ChirpKit` | 0 failures |
| Simulator | `scripts/test.sh` | `** TEST SUCCEEDED **` |
| Device | `scripts/run_device.sh` | launches |

## Scope

- **In scope:** new engine targets (see Step 1), a Keychain-backed key store, provider settings (including trusted LAN
  hosts), the privacy-class control on transcripts, the router enforcement and override confirmation, prompts and
  deliverables tables (migration), templates, map-reduce, Ask with timestamp citations, the Transforms tab and
  Transform button, Settings "Cloud models", `NSLocalNetworkUsageDescription` and App Transport Security local
  networking, contracts for deliverables, THIRD_PARTY_LICENSES.
- **Must not change:** transcripts are never overwritten by generated text; `rawTranscript` and words untouched; no
  content in logs or the run ledger; the default privacy class; M1–M3 behavior.
- **Out of scope:** structure models (M6), MLX and llama.cpp small models (M7), the Share-sheet Transform extension
  (M8), Apple Private Cloud Compute (entitlement-gated).

## Git workflow

Branch `m4/language-models` in its own worktree. Commit after each step. No assistant trailers. Do not push.

## Steps

### Step 1: Spike AnyLanguageModel vs direct ports (half a day, then decide)

Evaluate Hugging Face AnyLanguageModel (Apache-2.0) as the implementation inside one `ChirpEngineLanguageModels`
target: Apple Foundation Models, Anthropic, OpenAI-compatible, Gemini, Ollama behind one API. Criteria: Swift 6 strict
concurrency clean, streaming, cancellation, structured output, iOS 26 support, no extra network calls. Otherwise port
upstream's `LLMClient` adapters into `ChirpEngineHTTPLLM` and write `ChirpEngineAppleFM` for Foundation Models. Record
the decision as ADR-011 using the [template](../../spec/adr/000-template.md).

### Step 2: Keys and providers

Keychain store behind a protocol (fake in package tests; the real Keychain in app-hosted tests). Settings → Models:
add a provider (type, base URL, key, model), mark a LAN host trusted, test connection. Add
`NSLocalNetworkUsageDescription` and `NSAllowsLocalNetworking` for LAN HTTP. Keys never in `UserDefaults` or logs.

### Step 3: Privacy class and routing

Add the privacy-class control to Transcript (general / personal / clinical). Every generation path calls
`PrivacyRoutingPolicy.allows` with the item's class; a clinical item with a cloud (or untrusted LAN) provider shows a
per-run confirmation ("Send this clinical transcript to <provider>?"). The override is logged without content.

**Verify:** tests at each call site with a fake cloud model prove clinical text is never sent without the override.

### Step 4: Templates, deliverables and the run ledger

Migration: `prompts`, `prompt_versions` (immutable), `deliverables` (transcript id, template version, provider,
model, text, privacy class inherited), `llm_runs` (provider, model, duration, token counts, success; **no content**).
Built-in templates: Summary, Meeting notes, Action items, Agenda, SOAP note (defaults its output to `clinical`),
Polish, Distill, Decide, Brief. Renderer supports `{{transcript}}` and `{{userNotes}}`.

### Step 5: Long transcripts (map-reduce)

Port upstream map-reduce and make it the default when the transcript exceeds the model's context (read
`contextSize` at run time for Foundation Models; ~4K tokens). Never silently truncate a clinical transcript; if it
cannot be processed, say so.

**Verify:** chunking tests on a synthetic long transcript; a fake model records that every chunk was seen.

### Step 6: UI

Transforms tab lists templates and recent deliverables; Transcript → Transform opens the template picker; results
stream into an editable document with Copy and Share; Ask tab per the handoff (locality chip shows the real route,
citation chips seek the player). Replace every M4 placeholder.

## Test plan

- Router enforcement at every call site (clinical × cloud × override matrix).
- Fake `LanguageModel` for streaming, cancellation and errors; renderer tests; map-reduce tests; migration tests.
- Device QA: Foundation Models on the iPhone 17 Pro (Apple Intelligence on), a LAN Ollama on the owner's Mac, one
  cloud provider; SOAP note from a synthetic clinical transcript never reaches the cloud without confirmation.

## Done criteria

- [ ] Every template produces a stored deliverable from a transcript with on-device, LAN and cloud providers
- [ ] Clinical routing proven by tests and by a device check; ledger has no content
- [ ] Ask answers with working timestamp citations
- [ ] ADR-011 written; spec/08 moves from PROPOSAL to ACTIVE; privacy table updated; contracts written
- [ ] Focused and full suites green once; `scripts/test.sh` green; everything committed; nothing pushed

## STOP conditions

- Any path that could send clinical text off the device without the per-run override.
- A provider requires storing a key outside the Keychain.
- An entitlement (Private Cloud Compute, Foundation Models adapters) would be needed: owner decision.
- AnyLanguageModel and direct ports both fail the Step 1 criteria: report and ask.

## Maintenance notes

- Prompt versions are immutable; deliverables reference the version used.
- Foundation Models availability depends on Apple Intelligence being on; show a clear state when it is off.
- iOS 27's `LanguageModel` protocol and Core AI arrive behind `#available` and Xcode 27 (M7).
