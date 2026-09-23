# Plan: M7 — Engine breadth and on-device benchmarks

> **Executor instructions:** Follow this plan step by step. Run every verification command and confirm the expected
> result before moving on. If anything in "STOP conditions" occurs, stop and report; do not improvise. When done,
> update this plan's row in [`docs/plans/README.md`](README.md) and the M7 row in
> [`spec/README.md#milestones`](../../spec/README.md#milestones).
>
> **Drift check (run first):** written at `bd8cfc7c`, before M1 code existed.
> 1. `grep -n "^| \[003\]\|^| \[011\]" docs/plans/README.md` → both **IMPLEMENTED** (streaming engines serve M2's live
>    session). If not, STOP.
> 2. `git diff --stat bd8cfc7c..HEAD -- ChirpKit/Sources/ChirpCore/Engines ChirpKit/Sources/ChirpEngineFluidAudio ChirpKit/Package.swift`,
>    then confirm "Current state". Refine and commit before coding; STOP if the approach changes.

## Status

- **Milestone:** M7
- **Priority:** P2
- **Effort:** L (several independent engine targets plus a benchmark harness; parallel lanes)
- **Risk:** MEDIUM (memory, model downloads, a breaking WhisperKit upgrade)
- **Depends on:** plans 003 and 011 IMPLEMENTED; 013 for the language-model engines
- **Governing docs:** [spec/06 engine matrix](../../spec/06-speech-engines.md#engine-matrix-plan),
  [ADR-004](../../spec/adr/004-engine-plugin-architecture.md), [speech-engine plug-in contract](../../spec/contracts/speech-engine-plugin-v1.md),
  [on-device runtimes research](../research/2026-09-22-on-device-runtimes.md)
- **Planned at:** commit `bd8cfc7c`, 2026-09-22
- **Status:** IN PROGRESS — ASR lane (`lane/asr-engines`: Steps 1, 2, 4, 6; Step 3 optional). Step 5 (small
  language models) is a separate lane.

## Drift check and refinement (ASR lane, at `f325b99c`)

1. Plan 003 is **IMPLEMENTED**. Plan 011 is **IN PROGRESS**, but only for the owner's device QA: Steps 1–8 are built and
   merged, with `SMOKE PASS` on both phones. The live-session seam that M7 needs (`LiveSpeechSessionProviding`,
   `TailWindowPreviewSession`) exists and is tested, so this does not STOP the lane. The controller assigned the lane
   knowing this.
2. `git diff --stat bd8cfc7c..HEAD` over the engine paths shows the M1–M6 growth the "Current state" section expected,
   plus more. ChirpCore gained `LiveSpeechSession`, `VoiceActivity`, `SpeechSynthesis`, `DecisionModel` and
   `CompanionConfiguration`. `ChirpEngineFluidAudio` now has `ParakeetEngine` (with the tail-window preview),
   `FluidAudioDiarizer`, `FluidAudioVoiceActivity` and the shared `ModelAssetLifecycle`. `EngineDescriptor` is
   unchanged apart from new kinds. Every consumer (`FileTranscriptionPipeline`, `DictationCoordinator`,
   `MeetingCoordinator`, `MeetingLiveTranscriber`, `MeetingFinalizer`) already takes `any SpeechEngine`. The
   Parakeet variant is fixed at launch (`AppEnvironment.runningVariant`). The approach does not change.

Refinements (they add detail and change none of the plan's decisions):

- **Registry (Step 1).** Upstream's `SpeechEngineCapabilityRegistry` is ported into ChirpCore as data rows keyed by
  `(engine id, variant)`. ChirpCore cannot import engine targets. Each engine's test pins its descriptor to its row.
  A row carries a runtime-memory estimate. Rows above the memory budget (2.5 GB, from spec/06) are marked and cannot
  be selected.
- **Routes (Step 1).** `SpeechEngineRouter` (ChirpCore) conforms to `SpeechEngine` and `LiveSpeechSessionProviding`.
  It is passed wherever the app passed `engines.speech`.
  - Consumers take their route's engine once, when a job is queued, with `SpeechRouting.resolve(_:for:)`: one line
    each.
  - **Live** serves the dictation preview and a meeting's live text. **Final** produces every kept transcript: files,
    a dictation's final pass and a meeting's final pass. This follows spec/06 ("the final route produces the stored
    transcript"). Upstream differs: there, a dictation's final pass follows the live engine.
  - A meeting holds a router lease from start until it reaches a finished state, and route changes are refused while
    any lease is held. Existing transcripts keep their `engine` ids. Parakeet v3 stays the default for both routes.
- **Tail preview for any engine.** `TailWindowPreviewSession` moves from `ChirpEngineFluidAudio` to ChirpCore
  unchanged. An engine without its own live mode (Apple Speech, WhisperKit) can then serve the live route: the router
  writes each window to a temporary WAV and calls `transcribe`.
- **Apple Speech (Step 2).** `SpeechTranscriber` plus `SpeechAnalyzer` over the normalized WAV. Word timings come from
  `audioTimeRange`. Assets are handled through `AssetInventory`: `assetInstallationRequest` downloads and reserves the
  locale, and delete releases the reservation. A Mac probe needed no speech-recognition permission and no entitlement.
  `DictationTranscriber` and custom vocabulary are deferred.
- **WhisperKit (Step 4).** Package `argmax-oss-swift`, pinned exactly to `1.1.0` (MIT, checked 2026-09-22). Only the
  `WhisperKit` product is linked (it depends on `ArgmaxCore` alone). Two variants: `base` (147 MB) and
  `large-v3-turbo` (`openai_whisper-large-v3-v20240930_turbo_632MB`, 646 MB). WhisperKit would fetch the tokenizer from
  Hugging Face at load time, so `downloadAssets` fetches it with the model. `prepare` refuses when it is missing.
  WhisperKit does not use FluidAudio's `ANEInferenceGate`, which is internal to that target and does not serialize on
  iOS 26. The scheduler still runs background jobs one at a time.
- **Benchmark (Step 6).** Results live in a JSON file in Application Support. No database table, so no migration.
  `v9-engine-benchmarks` is not used. The reference set is synthetic (`say`) with known text:
  `scripts/make_benchmark_audio.sh` bundles it, and the Mac harness makes it at test time. The research doc is
  `docs/research/2026-09-22-asr-engine-benchmarks.md` (Mac numbers). The controller adds the iPhone numbers.

## Why this matters

"Plug and play various different speech-to-text engines, large language models, and small language models" needs
more than one of each, and a fair way to choose between them on the owner's phone. This milestone adds the next
engines from the plan's matrix and an on-device benchmark screen so choices are made with numbers.

## Current state (expected after M1, M2 and M4)

- One speech engine (`ParakeetEngine`), one diarizer, the live-session protocol with a tail-window Parakeet preview,
  M4 language-model engines. `EngineDescriptor` carries basic capabilities.
- Upstream to port: `SpeechEngineCapabilityRegistry` (one row per variant: native live, tail preview, word
  timestamps, language policy, custom vocabulary, memory floor), live/final routes and leases (ADR-016/026),
  `WhisperEngine` (retry without a forced language when empty), `NemotronEngine`, benchmark contract ideas from
  `upstream/macparakeet/benchmarks/asr/`.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Focused tests | `scripts/check.sh <EngineTarget>Tests` | green, lint clean |
| Real-model tests (per engine) | `CHIRP_MODEL_TESTS=1 swift test --package-path ChirpKit --filter <Engine>IntegrationTests` | green |
| Full package suite (once) | `swift test --package-path ChirpKit` | 0 failures |
| Device | `scripts/run_device.sh`; `scripts/device_smoke.sh` | launches; `SMOKE PASS` |

## Scope

- **In scope (one lane each):**
  1. Capability registry port and an engine picker with separate live and final routes.
  2. `ChirpEngineAppleSpeech`: `SpeechTranscriber` (and `DictationTranscriber` for custom vocabulary), models via
     `AssetInventory`; device-only tests (not available in the Simulator).
  3. FluidAudio streaming (Parakeet EOU and/or Nemotron) as `LiveSpeechSession` conformers for dictation preview.
  4. `ChirpEngineWhisperKit` on `argmax-oss-swift` 1.1 (MIT; a breaking upgrade from upstream's 0.18); large-v3 turbo
     (626 MB) with incremental loading.
  5. Small language models: MLX Swift (foreground only; needs Xcode builds for Metal) and llama.cpp GGUF (one actor);
     defaults Qwen3.5-2B or LFM2.5-1.2B, quality tier Qwen3-4B-Instruct-2507.
  6. Benchmark harness and screen: synthetic reference set (known text) plus user-chosen files; word error rate,
     real-time factor, first-load time, peak memory, battery note; results stored locally and exportable.
- **Must not change:** Parakeet v3 stays the default; the plug-in rule (no SDK imports outside engine targets);
  existing transcripts keep their `engine` ids; clinical routing.
- **Out of scope:** Core AI and iOS 27 Speech APIs until the Mac has Xcode 27 (then behind `#available`); Cohere
  (1.8 GB; only after memory measurements); Cactus (gated, only if asked).

## Git workflow

One branch and worktree per lane (`m7/<lane>`). Commit after each step. No assistant trailers. Do not push. Each new
dependency bump follows the pin discipline in [spec/06](../../spec/06-speech-engines.md#fluidaudio-pin-and-bump-discipline).

## Steps

### Step 1: Capability registry and routes

Port the registry and the live/final route selection with snapshots at enqueue and meeting leases. Engine picker in
Settings shows only engines whose models are ready or downloadable, with size and capabilities.

### Step 2–5: One engine per lane

For each engine: target, descriptor (stable id, license), asset management (explicit download only), conformance
tests with fakes, a gated real-model integration test, a descriptor row in the registry, THIRD_PARTY_LICENSES row.
Measure memory on the device before exposing it; engines above the budget are hidden or marked.

### Step 6: Benchmark harness

A DEBUG-and-Settings screen that runs selected engines over the synthetic set and user files one at a time through the
scheduler, recording the metrics above into a local results file, exportable as CSV/JSON. Write
`docs/research/<date>-device-benchmarks.md` from a run on the iPhone 17 Pro.

## Test plan

- Conformance tests per engine (contract semantics: no implicit download, monotonic timestamps, cancellation).
- Registry and routing tests (snapshot at enqueue, lease blocks switch).
- Device: each engine transcribes the synthetic sample; benchmark screen completes.

## Done criteria

- [ ] At least Apple SpeechTranscriber, one streaming FluidAudio engine, WhisperKit and one small LLM runtime are
      selectable and pass conformance tests
- [ ] Live and final routes selectable separately; meeting lease honored
- [ ] Benchmark results recorded in `docs/research/`
- [ ] spec/06 matrix and THIRD_PARTY_LICENSES updated; focused and full suites green once; everything committed; nothing pushed

## STOP conditions

- An engine needs the Increased Memory Limit or another entitlement to be useful: owner decision (account change).
- A dependency's license conflicts with GPL-3.0 (route through ADR-010).
- A dependency bump changes FluidAudio's pinned version without the bump procedure.

## Maintenance notes

- Engine ids are forever; variants distinguish builds of the same family.
- Keep GPU runtimes foreground-only and say so in the UI.
