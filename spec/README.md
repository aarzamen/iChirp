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
| 05 | [Audio pipeline](05-audio-pipeline.md) | Decoding, storage, capture for dictation and meetings, background audio | ACTIVE (M1 decoding, M1.5 continued processing, M2 capture); the M3 meeting section is built, device checks pending |
| 06 | [Speech engines](06-speech-engines.md) | Engine plug-ins, Parakeet via FluidAudio, scheduler, diarization, pin discipline | ACTIVE |
| 07 | [Text processing](07-text-processing.md) | Deterministic clean-up, words, segments, paragraphs, cues, titles | ACTIVE |
| 08 | [Language and structure models](08-language-and-structure-models.md) | LLM/SLM providers, deliverable templates, Needle/Jev/Laya | ACTIVE for language models (M4 core and screens), the M6 Needle slice and the Jev trial (M6a); Laya PROPOSAL |
| 09 | [Testing](09-testing.md) | Test layers, fixtures, gated tests, device smoke, agent test loop | ACTIVE |
| 10 | [Agent working method](10-ai-coding-method.md) | Source-of-truth precedence, context zone, plans, review, definition of done | ACTIVE |
| 11 | [Ingest](11-ingest.md) | Share sheet, Voice Memos, podcasts, links, YouTube, PDFs and text documents | ACTIVE (M1.5, M5, plan 019 YouTube audio via the Mac companion; share extension still a proposal) |
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
| `main` (development source, public on GitHub) | Unreleased | The working branch: lanes branch from `main` and merge back locally, and `main` reaches GitHub when the owner asks for a push. Until 2026-10-01 work landed on the `ichirp/foundation` integration branch first; it was fast-forwarded into `main` at `47eeefb1` and retired. A source revision is not a release. |
| Developer device build | Owner's iPhone only | Installed with `scripts/run_device.sh` from whatever commit was checked out. Identify it in Settings → About (version, build, commit, branch, date). |
| Sideload build (IPA) | none yet | `scripts/build_ipa.sh` can produce one. When an IPA is first installed through SideStore, record its version (build) and commit here. |

Feature flags. An implemented flag-gated surface is not a shipped feature.

| Flag | Kind | Value | Notes |
|---|---|---|---|
| `-ChirpSmoke transcribe-sample` | DEBUG launch argument | Off unless passed | Runs the smoke transcription and writes `Documents/smoke-result.json`. Compiled out of Release builds. |
| `CHIRP_*=1` test switches | Test environment variables | Unset | Enable the real-model and live-service tests (`CHIRP_MODEL_TESTS` downloads Parakeet; eleven more are listed). Not app flags; the full table is in [`09-testing.md`](09-testing.md#opt-in-test-switches). |
| `CHIRP_ENABLE_<PLUGIN>=1` | Build flag pattern ([ADR-010](adr/010-plugin-license-gate.md)) | None defined | Plug-ins whose license or binary-only runtime conflicts with GPL-3.0 (Cactus's engine and its binary `libneedle.a`) are compiled only when their flag is set, in personal builds. Needle 3 built from needle-rs source is not one of them ([ADR-012](adr/012-needle-from-needle-rs-source.md)). |
| `vendor/NeedleC.xcframework`, `vendor/llama.xcframework` | Build-time presence, not a flag | Absent until built | `ChirpKit/Package.swift` links Needle and llama.cpp only when these exist (made by `scripts/build_needle.sh` and `scripts/build_llamacpp.sh`; CI builds both). Without them Settings says "not in this build". Not license-gated ([ADR-012](adr/012-needle-from-needle-rs-source.md), [ADR-015](adr/015-on-device-llm-llama-cpp.md)). |

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
| [ADR-012](adr/012-needle-from-needle-rs-source.md) | Needle 3 on the iPhone built from needle-rs source (MIT) with Apache-2.0 weights; the ADR-010 gate does not apply to it |
| [ADR-013](adr/013-jev-decision-model.md) | Jev as an opt-in cloud decision model (`ChirpEngineJev`, `DecisionModel` contract); clinical items never sent |
| [ADR-014](adr/014-mac-companion.md) | The Parakeet companion on the owner's Mac (voices and YouTube audio) over the home network, with a pairing token |
| [ADR-015](adr/015-on-device-llm-llama-cpp.md) | Small language models on the iPhone through llama.cpp built from source (`ChirpEngineLlamaCpp`); Qwen3.5 2B default, Qwen3 4B Instruct quality tier; MLX Swift not adopted |
| [ADR-016](adr/016-transcript-corrections-over-an-immutable-baseline.md) | Transcript corrections over an immutable baseline: word-span corrections in one JSON column bound to a fingerprint of the words, applied only by the one accessor, written only by the correction service; pipelines keep or detach them; voice commands are corrections (plan 025) |
| [ADR-017](adr/017-your-own-templates.md) | Your own templates: one list with read-only built-ins (hide and move only), edits as immutable versions, soft delete with Restore, a raise-only clinical switch, app rules for text the person wrote (plan 026) |
| [ADR-018](adr/018-emr-note-app-rendered.md) | The EMR note: the model fills a JSON form, Parakeet writes the note (grid, headers, signature by code), the owner's lint rules and a number check run before Copy; the signature stays on the phone (Proposed, deferred: plan 027 saved for later) |

## Milestones

Each later milestone has an executor-ready plan; the [plans board](../docs/plans/README.md) tracks its state.

| Milestone | Scope | Status | Plan |
|---|---|---|---|
All of M0–M7 and the part of M8 listed below are merged on `main` (every lane branch is an ancestor of it; the SHAs
are the lane tips). "Device checks pending" means the owner's checklist in
[`human-qa-guide.md`](../docs/human-qa-guide.md) has not been walked on the phone.

| Milestone | Scope | Status | Plan |
|---|---|---|---|
| M0 | Foundation: restructure, XcodeGen project, ChirpKit targets, scripts, CI, specs and agent docs | Implemented on `main` (`e232b62d`) | [003](../docs/plans/2026-09-22-003-feat-m0-m1-implementation-plan.md) |
| M1 | Parakeet v3 file transcription: import, normalize, transcribe, speaker labels, Library, Transcript with player, export, model management, device smoke | Implemented on `main`: device smoke PASS on iPhone 17 Pro and iPhone 15 Pro; final review fix round merged, `a6cd8f2d`: 381 package tests, 18 app tests, lint clean, smoke PASS | [003](../docs/plans/2026-09-22-003-feat-m0-m1-implementation-plan.md) |
| M1.5 | `BGContinuedProcessingTask` for long files and model downloads, Share-sheet import ("Open in Parakeet"; the share extension plus App Group is gated), Voice Memos, audio-track choice | IN PROGRESS: built and merged on `main` (`1ad81930`), simulator-tested; device checks pending | [010](../docs/plans/2026-09-22-010-m1.5-share-and-background.md) |
| M2 | Dictation: audio session, live preview, final Parakeet pass, clean-up, copy, Action Button intent with a Live Activity | IN PROGRESS: built and merged on `main` (`085d13f7`); device checks pending | [011](../docs/plans/2026-09-22-011-m2-dictation.md) |
| M3 | Meeting recording: background audio, crash-safe recording plus `recording.lock` recovery, live chunks, final pass plus diarization, Notes tab | IN PROGRESS: built and merged on `main` (`78211054`: focused package tests, app tests, simulator record/kill/recover verified); device checks pending | [012](../docs/plans/2026-09-22-012-m3-meetings.md) |
| M4 | Language models and deliverables: providers, Keychain keys, templates (summary, meeting notes, agenda, SOAP, action items, Transforms), Ask with citations, privacy router | IN PROGRESS: core (`dd2ddb29`) and screens (`5db5fd30`) built and merged on `main`, simulator-verified; owner device QA pending. Plan 026 (your own templates: make, duplicate, edit as versions, hide, reorder, delete and restore; migration `v12-template-library`) merged on `main` (`af604e80`, `ecbac18d`); `device_smoke.sh` PASS on iPhone 17 Pro at `9fef357e` (2026-10-02); the templates QA checklist on the phone is pending. Plan 027 (the EMR note, ADR-018) is a design saved for later, deferred by the owner | [013](../docs/plans/2026-09-22-013-m4-language-models-and-deliverables.md), [026](../docs/plans/2026-10-01-026-your-own-templates.md), [027](../docs/plans/2026-10-02-027-emr-note-design.md) |
| M5 | Ingest breadth: podcasts, direct media links, YouTube strategy, PDF (text plus OCR), TXT/MD/RTF/DOCX import | IN PROGRESS: built and merged on `main` (`b49d8bd6`); open items finished by plan 019 (`d40ab48b`: YouTube audio via the Mac companion); device checks pending | [014](../docs/plans/2026-09-22-014-m5-ingest.md) |
| M6 | Structure models: Needle 3 (from needle-rs source, ADR-012), Jev (opt-in, non-clinical), Laya research; confidence gating | IN PROGRESS: merged on `main`: the Needle slice (`a9bca61e`; SOAP fields and medications, voice commands, an allow-list clinical gate `a27dd43a`, evidence ledger, Eval; Needle experimental at 44.6% argument accuracy) and the Jev trial (`41de1e3b`, plan 021; its live eval waits on the owner's Jev key); Needle round 4 (clinical safety) is open: do not use Extract fields on real clinical dictation until it lands; Laya not started | [015](../docs/plans/2026-09-22-015-m6-structure-models.md), [021](../docs/plans/2026-09-22-021-m6a-jev-decision-trial.md) |
| M7 | Engine breadth and on-device benchmarks: Apple SpeechTranscriber, WhisperKit, streaming Parakeet/Nemotron, MLX and llama.cpp | IN PROGRESS: merged on `main`: speech routes, Apple Speech, WhisperKit and the ASR benchmark (`287ae725`); small language models on the iPhone through llama.cpp (`4dc07f0e`, ADR-015; Qwen3.5 2B default, Qwen3 4B Instruct quality; MLX not adopted). iPhone measurements partly pending; streaming not built | [016](../docs/plans/2026-09-22-016-m7-engine-breadth.md) |
| M8 | Polish: PDF/DOCX export, keyboard extension, Transforms share extension, widgets, accessibility, iPad, localization | IN PROGRESS: PDF and Word export shipped with Create (plan 022, `08dccd2b`); the UX-audit polish (accessibility floor, Dynamic Type, 44 pt targets, contrast, honest privacy labels) and the dark palette (`7e5ac64b`) are merged; the 2026-10-01 full review's fixes (plan 024, 193 findings triaged) and transcript corrections with Find and Replace (plan 025: `4f9dc9bb`, `e88c91a0`, `12a31f71`; `SMOKE PASS` and `FIND BENCH PASS` on iPhone 17 Pro at `9fef357e`, 2026-10-02) are merged, owner device QA pending; keyboard, Transforms share extension, home-screen widgets, iPad and localization are not started | [017](../docs/plans/2026-09-22-017-m8-polish.md), [022](../docs/plans/2026-09-22-022-create-anything-in-anything-out.md), [023](../docs/plans/2026-09-23-023-owner-design-decisions.md), [024](../docs/plans/2026-10-01-024-review-fixes.md), [025](../docs/plans/2026-10-01-025-transcript-corrections-and-find.md) |

Status words match the plans board. When a milestone lands, update this row, the board and the root `README.md` status
table in the same commit, with the commit SHA and what was verified (package suite, simulator, device smoke).

## For coding agents

Start with [`AGENTS.md`](../AGENTS.md). It carries the commands, boundaries and product rules; this index carries
the decisions and state.
