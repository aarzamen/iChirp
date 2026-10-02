# 09 - Testing

> Status: ACTIVE — test layers, fixtures, gated tests, the device smoke test, and the agent test loop.

## Philosophy

- Test the logic where it lives: `ChirpKit` packages run on the Mac host with `swift test`; no simulator needed.
- Test view models, not SwiftUI views. Views stay thin; their decisions live in `ChirpFeatures`.
- Depth scales with risk. Persistence, the pipeline, the scheduler, privacy routing and contracts need the
  strongest tests; copy edits need none.
- Tests are **deterministic** (no fixed sleeps where a signal can be awaited), **fast** (unit tests well under a
  second), and **clear** (names describe scenario and outcome: `testMissingModelFailsWithActionableMessage`).
- Bug fixes keep a test that fails before the fix and passes after, when practical.

## Layers

| Layer | Where | Runs on | Command |
|---|---|---|---|
| Package unit and integration tests | `ChirpKit/Tests/<Module>Tests/` | Mac host | `scripts/check.sh <Filter>`; full: `swift test --package-path ChirpKit` |
| Real-model tests (Parakeet download, diarization) | `ChirpEngineFluidAudioTests` (`ParakeetEngineIntegrationTests`) | Mac host | `CHIRP_MODEL_TESTS=1 swift test --package-path ChirpKit --filter ParakeetEngineIntegrationTests` |
| App-hosted tests (include the clinical-confirmation guard) | `AppTests/` | iPhone simulator | `scripts/test.sh`; CI compiles them (`build-for-testing`) but does not run them |
| Script checks | `scripts/check_scripts.sh` and `scripts/fixtures/` | Mac | `scripts/check_scripts.sh` (CI runs it) |
| Companion tests | `companion/tests/` | Mac, Python 3.12 | `cd companion && uv run --frozen --python 3.12 pytest -q` (CI: `companion.yml`) |
| Simulator smoke | the app with `-ChirpSmoke transcribe-sample` | iPhone simulator (Core ML on CPU, slow but works) | `scripts/run_sim.sh -ChirpSmoke transcribe-sample` |
| **Device smoke** | same runner, on the owner's iPhone | iPhone 17 Pro | `scripts/device_smoke.sh` → prints `SMOKE PASS` plus metrics |
| Human QA | the checklist in the PR or plan | real phone, real audio | [`docs/human-qa-guide.md`](../docs/human-qa-guide.md) |

### What each package target covers (M1)

- `ChirpCoreTests`: model JSON round-trips, `displayTitle`/`displayText`, settings defaults, `AppPaths`,
  `BuildIdentity`, `PrivacyRoutingPolicy`, and the `SpeechJobScheduler` (priority, FIFO, cancellation, backpressure).
- `ChirpTextTests`: upstream tests ported with their names (word timing, speaker merger, segmenter, paragraphs,
  text pipeline, custom words, refinement, derivers). Skipped upstream cases are listed in the module README.
- `ChirpExportTests`: TXT, Markdown, SRT/VTT timecodes and cue breaks, JSON schema key.
- `ChirpStoreTests`: in-memory GRDB round-trips (including JSON columns), ordering, delete, stale-job recovery,
  metadata-preserving save, observation.
- `ChirpAudioTests`: every fixture normalizes to 16 kHz mono Float32; sample count within ±1 %; a non-audio file
  throws.
- `ChirpEngineFluidAudioTests`: ANE gate, descriptor, word-timing parity with ChirpText, not-downloaded behavior; the
  gated real-model test.
- `ChirpFeaturesTests`: the pipeline with fakes for every protocol (completed with speakers, missing model, diarizer
  failure is non-fatal, Raw vs Clean, title edited mid-job survives, cancellation), and Library filtering, search and
  day sections.

## Fixtures

- **Synthetic only.** Audio is generated with macOS `say` and `afconvert` (`scripts/make_sample_audio.sh`), or built
  at test time (the `.mov` fixture is written with AVAssetWriter in `setUp`, not committed).
- **Never** commit real recordings, real transcripts, patient data or anything resembling PHI, even "anonymized".
- Test-target fixtures live in `ChirpKit/Tests/<Module>Tests/Fixtures/`. The app's bundled smoke sample is
  `App/Resources/Samples/sample-two-voices.m4a` (two synthetic voices: "The quick brown fox jumps over the lazy dog."
  and "Parakeet runs entirely on this iPhone.").
- Model downloads for tests go to `~/Library/Caches/ichirp-test-models`, never into the repo.

## Doubles and helpers

- Every pipeline dependency is a `ChirpCore` protocol, so tests inject fakes: `FakeStore` (in-memory actor),
  `FakeNormalizer`, `FakeSpeech`, `FakeDiarizer`. Prefer actors for doubles.
- Name doubles by role: `Fake*` (working in-memory implementation), `Stub*` (fixed answers), `Recording*` (captures
  calls).
- Use an in-memory database (`DatabaseManager.inMemory()`) for store tests.
- Wait on signals (streams, continuations, polling with a timeout) instead of fixed sleeps. Timing-sensitive tests
  (the scheduler, the benchmark's memory samplers) are run repeatedly after any change to confirm they are not flaky:
  `swift test --package-path ChirpKit --jobs 3 --filter <Name>` in a loop, once with the Mac loaded.
- A fake that several readers share must answer from its **state**, never from a call counter: with a counter, which
  reader got which value depended on timing, and CI went red on a green commit (R8-1, `ASRBenchmarkTests`). Make the
  fake hold its value until the reader has read it.

## The agent test loop

1. While iterating, run only the focused tests for the areas you touched: `scripts/check.sh <TestFilter>` (builds,
   runs the filter, and lints strictly).
2. Run the full suite **once per task**, as the final gate: `swift test --package-path ChirpKit`, or, if the change
   touched `App/`, `Widgets/`, `UITests/` or `project.yml`, `scripts/test.sh` instead (it runs that same package suite
   first, then the app-hosted tests, which hold the clinical-confirmation guard); for `companion/` also its pytest suite.
3. If the change touches the pipeline (audio, engines, scheduler, store, coordinator), also run
   `scripts/device_smoke.sh` on the owner's iPhone. If the phone is locked or not paired, stop and ask the owner;
   do not claim device results from the simulator.
4. Report exactly which commands ran and their results. An old green run is not proof for the current change.
5. Do not start competing builds or test runs in the same worktree.

## Lint

`swift format lint --strict` over `ChirpKit/Sources`, `App/Sources`, `App/Shared` and `Widgets` is a hard gate from day
one (run by `scripts/check.sh` and CI). The test targets (`ChirpKit/Tests`, `AppTests`, `UITests`) are not linted.
`scripts/format.sh` rewrites files in place (it also formats `ChirpKit/Tests`, which nothing lints; review that diff
before committing).

## Continuous integration

`.github/workflows/ci.yml`: README reference check, `scripts/check_scripts.sh`, strict lint, the Needle and llama.cpp
runtime builds, the full package tests, project generation, an unsigned simulator build of the app **and its
app-hosted tests** (`build-for-testing`: compiled, not run), and then `scripts/check_privacy_manifest.sh --app` on the
built app (the privacy manifest against every binary's imports, including the Rust libraries; it comes last because it
reads the builds' output). `.github/workflows/companion.yml` runs the companion's pytest suite, and only when
`companion/` (or that workflow) changes; `ci.yml` ignores changes that only touch `docs/**`.
CI never signs, never needs secrets, and never downloads models. Actions are pinned by commit and XcodeGen by version
and checksum; the runner side of these workflows is only proven by a push (they cannot run locally).

The generated project has no committed `Package.resolved`, so the app build resolves packages itself. FluidAudio and
WhisperKit are pinned exactly in `ChirpKit/Package.swift`; GRDB is a range (`from: "7.0.0"`), so an app build can link a
newer GRDB than the one `ChirpKit/Package.resolved` tested. Pinning GRDB exactly would close that gap.

## Opt-in test switches

The default `swift test --package-path ChirpKit` skips these (they download models, call a service, or write to this
Mac's keychain). Set the switch on the command line for one run, e.g.
`CHIRP_MODEL_TESTS=1 swift test --package-path ChirpKit --filter ParakeetEngineIntegrationTests`. Synthetic content only.

| Switch | Test class | What it needs, downloads or calls |
|---|---|---|
| `CHIRP_MODEL_TESTS=1` | `ParakeetEngineIntegrationTests`, `FluidAudioVoiceActivityTests` | Downloads Parakeet v3, the diarizer and Silero VAD (~0.5 GB) into `~/Library/Caches/ichirp-test-models` and runs them on the synthetic sample |
| `CHIRP_APPLE_SPEECH_TESTS=1` | `AppleSpeechEngineIntegrationTests` | Apple's `SpeechTranscriber` on a macOS 26 Mac; may install the English speech model; skipped in the Simulator |
| `CHIRP_WHISPER_TESTS=1` (`CHIRP_WHISPER_VARIANT`, `CHIRP_WHISPER_MODELS_DIR`) | `WhisperKitEngineIntegrationTests` | Downloads a Whisper model from Hugging Face (Base ~150 MB by default) |
| `CHIRP_BENCHMARK=1` (`CHIRP_BENCHMARK_ENGINES`, `CHIRP_BENCHMARK_OUT`, `CHIRP_WHISPER_MODELS_DIR`) | `ASRBenchmarkMacRunTests` | Every speech engine over the synthetic reference set on the Mac; downloads any missing model (Parakeet ~0.5 GB, Whisper Base ~150 MB, Large v3 Turbo ~650 MB; macOS installs Apple's English model); writes CSV and JSON |
| `CHIRP_NEEDLE_TESTS=1` (`CHIRP_NEEDLE_WORK_DIR`, `CHIRP_NEEDLE_MODEL_FILE`) | `NeedleRealModelTests`, `NeedleEvalRealTests` | Needs `scripts/build_needle.sh` run first; uses `vendor/models/needle3.cact` or downloads the pinned file (35 MB) from Hugging Face into `vendor/models-cache/`; the eval takes about 15 minutes |
| `CHIRP_ONDEVICE_LLM_TESTS=1` (`CHIRP_ONDEVICE_LLM_DIR`, `_MODELS`, `_REPEATS`) | `LlamaCppRealModelTests` | Needs `scripts/build_llamacpp.sh` run first; downloads each pinned GGUF model once (Qwen3.5 2B ~1.5 GB, Qwen3 4B ~2.7 GB; SHA-256 checked) into `~/Library/Caches/iChirpTests/ondevice-llm` and runs a synthetic SOAP note through the app's `DeliverableService` |
| `CHIRP_LLM_TESTS=1` | `HTTPLanguageModelTests` (live), `AppleFoundationLanguageModelTests` (real) | Calls an LM Studio server that already answers on `http://localhost:1234/v1/models`; and Apple's on-device model on a Mac with Apple Intelligence |
| `CHIRP_JEV_TESTS=1` plus `JEV_API_KEY` | `JevLiveEvalTests` | Calls Jev's cloud API with the owner's key; synthetic excerpts only; never clinical |
| `CHIRP_LIVE_NETWORK_TESTS=1` | `LiveIngestTests` | The internet: Apple's podcast lookup and one public YouTube video's captions (ids and metadata only) |
| `CHIRP_LIVE_VOICE_TESTS=1` (`CHIRP_COMPANION_TOKEN`, `_HOST`, `_PORT`, `_VOICE`, `XAI_API_KEY`, `CHIRP_LIVE_VOICE_OUT`) | `VoiceLiveTests` | A running Mac companion and, with a key in the environment, xAI; one synthetic sentence each; never reads the Keychain |
| `CHIRP_KEYCHAIN_TESTS=1` | `KeychainSecretStoreTests` | Writes and deletes one throwaway item in this Mac's login keychain |
| `CHIRP_EXPORT_SAMPLES=<folder>` | `DocumentExportTests` | Writes sample PDF and Word exports into the folder, to look at |

Simulator tours (`UITests/`, their own schemes; never part of `scripts/test.sh`) and the app-hosted render tests read
`CHIRP_SCREENSHOT_DIR`, `CHIRP_RENDER_DIR`, `CHIRP_TOUR_MIC` and similar variables (through `TEST_RUNNER_<name>` for
UI tests); each file's header says which.

## Adding a test

1. Put it in the target of the module it tests, in a file named `<Feature>Tests.swift`.
2. Inject fakes through the `ChirpCore` protocols; never reach for a real model or network.
3. Run `scripts/check.sh <YourTestClass>` until green, then the full suite once.
4. If it pins a contract, name it in that contract's "Tests that enforce this" section.
