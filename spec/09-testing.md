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
| App-hosted tests | `AppTests/` | iPhone simulator | `scripts/test.sh` |
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
  (the scheduler) are run repeatedly after any change to confirm they are not flaky.

## The agent test loop

1. While iterating, run only the focused tests for the areas you touched: `scripts/check.sh <TestFilter>` (builds,
   runs the filter, and lints strictly).
2. Run the full package suite **once per task**, as the final gate: `swift test --package-path ChirpKit`.
3. If the change touches the pipeline (audio, engines, scheduler, store, coordinator), also run
   `scripts/device_smoke.sh` on the owner's iPhone. If the phone is locked or not paired, stop and ask the owner;
   do not claim device results from the simulator.
4. Report exactly which commands ran and their results. An old green run is not proof for the current change.
5. Do not start competing builds or test runs in the same worktree.

## Lint

`swift format lint --strict` over `ChirpKit/Sources` and `App/Sources` is a hard gate from day one (run by
`scripts/check.sh` and CI). `scripts/format.sh` rewrites files in place; review the diff before committing.

## Continuous integration

`.github/workflows/ci.yml` (added with the scripts): README reference check, full package tests, project generation,
and a simulator build without signing. It skips changes that only touch `docs/**`. CI never signs, never needs
secrets, and never downloads models.

## Adding a test

1. Put it in the target of the module it tests, in a file named `<Feature>Tests.swift`.
2. Inject fakes through the `ChirpCore` protocols; never reach for a real model or network.
3. Run `scripts/check.sh <YourTestClass>` until green, then the full suite once.
4. If it pins a contract, name it in that contract's "Tests that enforce this" section.
