# iChirp Spec Index

> Status: ACTIVE — authoritative index of product behavior, locked decisions, release channels and milestones.

**iChirp** (home-screen name **Parakeet**) is a private, local-first iPhone app that turns voice files, meetings,
links, device files, text files and PDFs into transcripts and finished documents, with plug-and-play speech engines,
language models and structure models. It is the iPhone edition of MacParakeet and ports its pipeline from a pinned
read-only copy in `upstream/macparakeet/`. The approved foundation design is
[`docs/plans/2026-09-22-002-feat-ichirp-foundation-design.md`](../docs/plans/2026-09-22-002-feat-ichirp-foundation-design.md).

## Spec documents

Every spec starts with a `> Status:` line. **ACTIVE** means it governs code that exists or is being built now.
**PROPOSAL** means it describes a later milestone; its executor plan refines it before any code is written.

| # | Document | Purpose | Status |
|---|---|---|---|
| 00 | [Vision](00-vision.md) | End goal, north star, principles, who it is for | ACTIVE |
| 01 | [Data model](01-data-model.md) | GRDB schema, migrations, on-disk layout | ACTIVE |
| 02 | [Features](02-features.md) | Feature behavior by milestone; honest placeholders | ACTIVE |
| 03 | [Architecture](03-architecture.md) | Modules, dependency rules, composition root, concurrency | ACTIVE |
| 04 | [UI](04-ui.md) | Tokens, tabs, screens, components, copy rules | ACTIVE |
| 05 | [Audio pipeline](05-audio-pipeline.md) | Decoding, storage, later capture and background audio | ACTIVE (M1 decode); later sections PROPOSAL |
| 06 | [Speech engines](06-speech-engines.md) | Engine plug-ins, Parakeet via FluidAudio, scheduler, diarization, pin discipline | ACTIVE |
| 07 | [Text processing](07-text-processing.md) | Deterministic clean-up, words, segments, paragraphs, cues, titles | ACTIVE |
| 08 | [Language and structure models](08-language-and-structure-models.md) | LLM/SLM providers, deliverable templates, Needle/Jev/Laya | ACTIVE for language models (M4 core); PROPOSAL for structure models (M6) |
| 09 | [Testing](09-testing.md) | Test layers, fixtures, gated tests, device smoke, agent test loop | ACTIVE |
| 10 | [Agent working method](10-ai-coding-method.md) | Source-of-truth precedence, context zone, plans, review, definition of done | ACTIVE |
| 11 | [Ingest](11-ingest.md) | Share sheet, Voice Memos, podcasts, links, YouTube, PDFs and text documents | PROPOSAL (M1.5, M5) |
| 12 | [Privacy](12-privacy.md) | Privacy classes, router, network surfaces, PHI rules, keys | ACTIVE |

## Boundary contracts

[`spec/contracts/`](contracts/README.md) holds the tested boundaries other code depends on: the speech-engine
plug-in protocol, the transcript JSON export, and the on-disk media layout. Change a contract and its focused tests
in the same commit.

## Design references

- [`04-ui.md`](04-ui.md) is the active UI contract.
- [Design handoff](../docs/plans/2026-09-22-001-feat-iphone-app-design-handoff.md): per-screen text description of
  the owner's design canvas, with M1 status and copy corrections.
- The canvas source files: [`docs/design/2026-09-21-iphone-canvas/`](../docs/design/2026-09-21-iphone-canvas/canvas.json)
  (live canvas: "MacParakeet for iPhone", <https://claude.ai/artifact/3KyBVG6YkYwGA97kW1nmiZ>).

## Root decisions (locked)

These are settled. Change one only through a dated ADR amendment approved by the owner.

| Decision | Choice | ADR |
|---|---|---|
| Relationship to MacParakeet | Port code into iChirp's own modules from a pinned, read-only upstream copy; never edit upstream in place | [001](adr/001-port-with-pinned-upstream-reference.md) |
| Privacy | Local-first; every item has a privacy class; clinical content stays on device or on a trusted home-network host | [002](adr/002-local-first-and-privacy-classes.md) |
| Default speech engine | Parakeet TDT v3 through FluidAudio, pinned exact 0.16.1, on Core ML / Neural Engine | [003](adr/003-parakeet-via-fluidaudio-default-engine.md) |
| Engines | Plug-in targets (`ChirpEngine<Provider>`) behind `ChirpCore` protocols: speech, language, structure, diarization | [004](adr/004-engine-plugin-architecture.md) |
| Project and code layout | XcodeGen `project.yml`; thin app target; all logic in the local `ChirpKit` package | [005](adr/005-xcodegen-and-chirpkit.md) |
| Platform | Minimum iOS 26.0; Swift 6 language mode with strict concurrency | [006](adr/006-minimum-ios-26.md) |
| Persistence | SQLite through GRDB 7; migrations registered inline and never edited once installed | [007](adr/007-grdb-persistence.md) |
| Distribution | Developer builds signed by the paid team `XM6E4PUXTU` and installed with `devicectl`; SideStore IPA is an optional fallback; a visible build identity in every build | [008](adr/008-distribution-and-build-identity.md) |
| Clean-up | Deterministic pipeline; **Raw** is the default | [009](adr/009-deterministic-cleanup-raw-default.md) |
| Licensing | GPL-3.0; incompatible plug-ins only behind opt-in flags in personal builds | [010](adr/010-plugin-license-gate.md) |

## Release channels and feature flags

> Canonical release-status block. Other docs link here instead of restating it.

| Channel | Status | Notes |
|---|---|---|
| `main` (development source) | Unreleased | M0/M1 work lands on the `ichirp/foundation` branch first and merges to `main` when the owner decides. A source revision is not a release. |
| Developer device build | Owner's iPhone only | Installed with `scripts/run_device.sh` from whatever commit was checked out. Identify it in Settings → About (version, build, commit, branch, date). |
| Sideload build (IPA) | none yet | `scripts/build_ipa.sh` can produce one. When an IPA is first installed through SideStore, record its version (build) and commit here. |

Feature flags. An implemented flag-gated surface is not a shipped feature.

| Flag | Kind | Value | Notes |
|---|---|---|---|
| `-ChirpSmoke transcribe-sample` | DEBUG launch argument | Off unless passed | Runs the smoke transcription and writes `Documents/smoke-result.json`. Compiled out of Release builds. |
| `CHIRP_MODEL_TESTS=1` | Test environment variable | Unset | Enables the real-model tests that download Parakeet. Not an app flag. |
| `CHIRP_ENABLE_<PLUGIN>=1` | Build flag pattern ([ADR-010](adr/010-plugin-license-gate.md)) | None defined | License-gated plug-ins (Needle, Cactus) are compiled only when their flag is set, in personal builds. |

No runtime product flags exist yet. When the first one is needed, add it as a `static let` in a `ChirpCore`
`AppFeatures` enum (the upstream pattern: DEBUG builds may honor a launch argument; Release ignores it) and add a
row here in the same commit.

## Architecture decision records

ADRs live in [`spec/adr/`](adr/) and use [`000-template.md`](adr/000-template.md). Amend an ADR with a dated
section; never delete its history.

| ADR | Decision |
|---|---|
| [ADR-001](adr/001-port-with-pinned-upstream-reference.md) | Port from a pinned, read-only MacParakeet reference with provenance headers |
| [ADR-002](adr/002-local-first-and-privacy-classes.md) | Local-first processing; privacy classes and the routing rule |
| [ADR-003](adr/003-parakeet-via-fluidaudio-default-engine.md) | Parakeet TDT v3 via FluidAudio (exact 0.16.1) is the default speech engine |
| [ADR-004](adr/004-engine-plugin-architecture.md) | Engine plug-in architecture: kinds, descriptors, locality, one target per provider |
| [ADR-005](adr/005-xcodegen-and-chirpkit.md) | XcodeGen project plus the ChirpKit local package |
| [ADR-006](adr/006-minimum-ios-26.md) | Minimum iOS 26.0 |
| [ADR-007](adr/007-grdb-persistence.md) | GRDB persistence with inline migrations |
| [ADR-008](adr/008-distribution-and-build-identity.md) | Paid-team developer installs, optional SideStore IPA, visible build identity |
| [ADR-009](adr/009-deterministic-cleanup-raw-default.md) | Deterministic clean-up pipeline with Raw as the default |
| [ADR-010](adr/010-plugin-license-gate.md) | License gate for plug-ins that conflict with GPL-3.0 |
| [ADR-011](adr/011-language-model-providers-direct-ports.md) | Language models via direct ports (`ChirpEngineHTTPLLM`, `ChirpEngineAppleFM`), not AnyLanguageModel |

## Milestones

Each later milestone has an executor-ready plan; the [plans board](../docs/plans/README.md) tracks its state.

| Milestone | Scope | Status | Plan |
|---|---|---|---|
| M0 | Foundation: restructure, XcodeGen project, ChirpKit targets, scripts, CI, specs and agent docs | Implemented (branch `ichirp/foundation`, `e232b62d`) | [003](../docs/plans/2026-09-22-003-feat-m0-m1-implementation-plan.md) |
| M1 | Parakeet v3 file transcription: import, normalize, transcribe, speaker labels, Library, Transcript with player, export, model management, device smoke | Implemented (branch `ichirp/foundation`): device smoke PASS on iPhone 17 Pro and iPhone 15 Pro; final review fix round merged, `a6cd8f2d`: 381 package tests, 18 app tests, lint clean, smoke PASS | [003](../docs/plans/2026-09-22-003-feat-m0-m1-implementation-plan.md) |
| M1.5 | `BGContinuedProcessingTask` for long files, Share-sheet import (share extension plus App Group), Voice Memos | NOT STARTED | [010](../docs/plans/2026-09-22-010-m1.5-share-and-background.md) |
| M2 | Dictation: audio session, live preview, final Parakeet pass, clean-up, copy, Action Button intent with a Live Activity | NOT STARTED | [011](../docs/plans/2026-09-22-011-m2-dictation.md) |
| M3 | Meeting recording: background audio, crash-safe recording plus `recording.lock` recovery, live chunks, final pass plus diarization, Notes tab | NOT STARTED | [012](../docs/plans/2026-09-22-012-m3-meetings.md) |
| M4 | Language models and deliverables: providers, Keychain keys, templates (summary, meeting notes, agenda, SOAP, action items, Transforms), Ask with citations, privacy router | In progress: core (Steps 1–5) on `m4/language-models-core`; UI lane pending | [013](../docs/plans/2026-09-22-013-m4-language-models-and-deliverables.md) |
| M5 | Ingest breadth: podcasts, direct media links, YouTube strategy, PDF (text plus OCR), TXT/MD/RTF/DOCX import | NOT STARTED | [014](../docs/plans/2026-09-22-014-m5-ingest.md) |
| M6 | Structure models: Needle 3 (personal builds), Jev (opt-in, non-clinical), Laya research; confidence gating | NOT STARTED | [015](../docs/plans/2026-09-22-015-m6-structure-models.md) |
| M7 | Engine breadth and on-device benchmarks: Apple SpeechTranscriber, WhisperKit, streaming Parakeet/Nemotron, MLX and llama.cpp | NOT STARTED | [016](../docs/plans/2026-09-22-016-m7-engine-breadth.md) |
| M8 | Polish: PDF/DOCX export, keyboard extension, Transforms share extension, widgets, accessibility, iPad, localization | NOT STARTED | [017](../docs/plans/2026-09-22-017-m8-polish.md) |

Status words match the plans board. When a milestone lands, update this row, the board and the root `README.md` status table in the same commit, with
the commit SHA and what was verified (package suite, simulator, device smoke).

## For coding agents

Start with [`AGENTS.md`](../AGENTS.md). It carries the commands, boundaries and product rules; this index carries
the decisions and state.
