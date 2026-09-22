# ChirpEngineFluidAudio

The on-device speech engines built on [FluidAudio](https://github.com/FluidInference/FluidAudio): Parakeet TDT
0.6B (v3 multilingual, v2 English) for transcription with word timestamps, and FluidAudio's offline diarizer
(pyannote Community-1) for speaker labels. Both conform to the ChirpCore engine contracts (`SpeechEngine`,
`SpeakerDiarizing`, `ModelAssetManaging`) and run CoreML on the Neural Engine. No audio leaves the device, and the
only network traffic is the explicit model download from Hugging Face.

The code is ported from MacParakeet's `STTRuntime` and `DiarizationService` (upstream `upstream/macparakeet` @
`bbae9e0e`). Ported files carry a provenance header naming their upstream path.

## Entry point

`Registration.swift`: `FluidAudioEngines.makeDefault(settings:)` builds the `ParakeetEngine` for the user's
`ParakeetVariant` plus the `FluidAudioDiarizer`. Both use FluidAudio's default model cache and the shared
`ANEInferenceGate`. Read `ModelAssetLifecycle.swift` next. It holds the lifecycle both engines share
(`downloadAssets` → `prepare` → `transcribe` / `diarize` → `deleteAssets`) and the rules for what may overlap.
Then read `ParakeetEngine.swift`.

## What's here

- `ModelAssetLifecycle.swift`: the generic actor both engines delegate to. It owns the download and load jobs
  (concurrent callers join one of each), the leases that in-flight jobs hold, and a generation counter. A delete
  refuses while a lease is out, bumps the generation, cancels and awaits in-flight work, and only then removes
  files. A load that finishes for an older generation is discarded. The FluidAudio calls come in through
  `Hooks`, which is also the test seam.
- `ParakeetEngine.swift`: the `SpeechEngine` actor. It downloads with `AsrModels.download` and loads with
  `AsrModels.loadLocal`, which reads local files only. Each `transcribe` checks out its own `AsrManager` (a
  `ParakeetWorker`) from an idle pool; all of them share one read-only `AsrModels`. It transcribes a 16 kHz mono
  file with a fresh `TdtDecoderState` inside the gate, forwards that manager's chunk progress for files longer
  than 15 s, and maps a BCP-47 `languageHint` onto FluidAudio's v3 script filter.
- `FluidAudioDiarizer.swift`: the `SpeakerDiarizing` actor. Holds upstream's `highAccuracyConfig`
  (`stepRatio 0.1`, `minSegmentDurationSeconds 0`, zero-vote re-embed), maps no-speech to an empty
  `DiarizationOutput`, renumbers speakers `S1…Sn` by first speech with `Speaker N` labels, and repairs a malformed
  PLDA JSON during `downloadAssets`. It builds `OfflineDiarizerModels` from the local `.mlmodelc` bundles and
  `plda-parameters.json` itself, because `OfflineDiarizerModels.load` downloads missing files.
- `ParakeetASRConfig.swift`: the `ASRConfig` and encoder compute units policy, plus `ChirpTuning` (the on-device
  tunables, starting with `parakeetParallelChunks = 2` on iOS). macOS mirrors upstream.
- `ANEInferenceGate.swift` and `AsyncPermit.swift`: ports of the process-wide Neural Engine mutex. It is a no-op
  on iOS and on macOS 15+, and serializes only on macOS 14.
- `WordTimingBuilder.swift`: an internal copy of upstream `STTWordTimingBuilder` that merges `▁` tokens into
  `WordTimestamp`s. It is a copy because this target must not depend on ChirpText.
- `FluidAudioModelLocations.swift`: model folders under the FluidAudio models root, cache-completeness checks
  (required files plus FluidAudio's pinned-revision marker), backup exclusion and on-disk size.
- `ModelDownloadTracker.swift`: maps FluidAudio's `DownloadProgress` phases onto one monotonic 0…1 bar, keeps the
  in-flight fraction and the last failure for `assetStatus()`, and maps errors onto `SpeechEngineError`.

## What to know before editing

- **FluidAudio is pinned exactly** (`exact: "0.16.1"` in `ChirpKit/Package.swift`). Bump it deliberately, never
  with a range. On every bump, diff the public API used here (`AsrModels`, `AsrManager`, `ASRConfig`,
  `TdtDecoderState`, `OfflineDiarizerModels`, `OfflineDiarizerManager`, `OfflineDiarizerConfig`, `ModelHub`,
  `Repo.revision`, `DownloadProgress`). Re-check `ModelDownloadTracker.fluidAudioDownloadWeight` against
  FluidAudio's `ProgressReporter`, and re-check the `.fluidaudio-revision` marker logic against its
  `ModelCache.matchesRevision`. Then run the gated real-model test below as the regression pass. A revision
  bump for a pinned repo (the diarizer) makes existing caches report `.notDownloaded`, by design.
- **Never download implicitly.** `assetStatus()` only reads the file system. Only `downloadAssets` touches the
  network. `prepare`, `transcribe` and `diarize` load strictly from local files, so never call
  `AsrModels.load`, `AsrModels.downloadAndLoad` or `OfflineDiarizerModels.load`: those go through
  `ModelHub.loadModels`, which downloads missing files and purges and re-downloads a cache that fails to load.
  Loading throws `SpeechEngineError.modelNotDownloaded(<engine id>)` (the descriptor id, as the engine contract
  says, never the display name) while the files are missing, while a download is in flight, and while a delete
  runs.
- **One `AsrManager` per concurrent job.** A manager has exactly one progress stream and one progress session.
  Two jobs on one manager trap in `AsyncStreamBuffer` ("attempt to await next() on more than one task"), or leak
  progress into each other. `ChirpCore`'s scheduler runs an interactive and a background job at once, so the
  engine pools managers. Upstream `STTRuntime` does the same with one manager per scheduler slot.
- **Deleting is refused while a job runs.** `deleteAssets` throws `SpeechEngineError.underlying` with an in-use
  message while any transcription or diarization holds a lease. Otherwise it waits for any download or load to
  finish cancelling before it removes files.
- **The ANE gate is never nested.** It is a plain mutex, not reentrant. Gate exactly one level per inference:
  the `AsrManager.transcribe` call and the `OfflineDiarizerManager.process` call. Never gate model loading or
  downloads, and never call a gated method from inside a gated body. The body runs in the caller's isolation,
  which is how the actors keep FluidAudio's non-Sendable types confined.
- Model folders are excluded from device backups after every successful download, because they can be
  re-downloaded. User data stays in backups (see ChirpCore's `AppPaths`).
- `WordTimingBuilder` must stay behavior-identical to ChirpText's `WordTimingBuilder`. `WordTimingParityTests`
  pins the shared token fixtures. Change both together.
- ChirpCore's engine protocols are contracts. Conform to them; do not change them from this target.

## How to verify

From the repository root:

```bash
scripts/check.sh ChirpEngineFluidAudioTests
```

This runs the package build, the unit tests and the strict lint. The unit tests never download: they cover the
gate, the descriptors, word timing, the not-downloaded paths, the lifecycle race rules, the per-job manager pool,
diarizer renumbering, PLDA repair and decoding, and progress mapping.

The real-model tests are skipped unless you opt in. They download Parakeet v3 (~0.5 GB) and the diarizer into
`~/Library/Caches/ichirp-test-models`. Then they transcribe and diarize
`ChirpKit/Tests/ChirpEngineFluidAudioTests/Fixtures/two-voices-16k.wav`, and run two concurrent transcriptions of
it looped past 15 s on one engine:

```bash
CHIRP_MODEL_TESTS=1 swift test --package-path ChirpKit --filter ParakeetEngineIntegrationTests
```

`swift test` runs on macOS only. To check that the iOS branches (`ParakeetASRConfig`, `ANEInferenceGate`)
compile, build the target for the simulator. `-quiet` prints only warnings and errors:

```bash
(cd ChirpKit && xcodebuild build -quiet -scheme ChirpEngineFluidAudio \
  -destination 'generic/platform=iOS Simulator' -skipMacroValidation -derivedDataPath .build/xcode-ios)
```
