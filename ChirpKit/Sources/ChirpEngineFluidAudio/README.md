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
`ANEInferenceGate`. Read `ParakeetEngine.swift` next. It shows the lifecycle every engine here follows:
`downloadAssets` → `prepare` → `transcribe` / `diarize`.

## What's here

- `ParakeetEngine.swift`: the `SpeechEngine` actor. Downloads with `AsrModels.download`, loads with
  `AsrModels.load` + `AsrManager.loadModels`, and transcribes a 16 kHz mono file with a fresh `TdtDecoderState`
  inside the gate. It forwards FluidAudio's chunk progress for files longer than 15 s, and maps a BCP-47
  `languageHint` onto FluidAudio's v3 script filter.
- `FluidAudioDiarizer.swift`: the `SpeakerDiarizing` actor. Holds upstream's `highAccuracyConfig`
  (`stepRatio 0.1`, `minSegmentDurationSeconds 0`, zero-vote re-embed), maps no-speech to an empty
  `DiarizationOutput`, renumbers speakers `S1…Sn` by first speech with `Speaker N` labels, and repairs a malformed
  PLDA JSON during `downloadAssets`.
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
- **Never download implicitly.** `assetStatus()` only reads the file system. `prepare`, `transcribe` and
  `diarize` check the cache first and throw `SpeechEngineError.modelNotDownloaded` rather than letting FluidAudio's
  loaders fetch missing files. Only `downloadAssets` touches the network. One known exception sits inside
  FluidAudio: if a cached model fails to load, `ModelHub.loadModels` purges the cache and re-downloads it once.
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
gate, the descriptors, word timing, the not-downloaded paths, diarizer renumbering, PLDA repair and progress
mapping. The real-model test is skipped unless you opt in. It downloads Parakeet v3 (~0.5 GB) and the diarizer
into `~/Library/Caches/ichirp-test-models`, then transcribes and diarizes
`ChirpKit/Tests/ChirpEngineFluidAudioTests/Fixtures/two-voices-16k.wav`:

```bash
CHIRP_MODEL_TESTS=1 swift test --package-path ChirpKit --filter ParakeetEngineIntegrationTests
```

`swift test` runs on macOS only. To check that the iOS branches (`ParakeetASRConfig`, `ANEInferenceGate`)
compile, build the target for the simulator. `-quiet` prints only warnings and errors:

```bash
(cd ChirpKit && xcodebuild build -quiet -scheme ChirpEngineFluidAudio \
  -destination 'generic/platform=iOS Simulator' -skipMacroValidation -derivedDataPath .build/xcode-ios)
```
