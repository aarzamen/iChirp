# ChirpEngineFluidAudio

The on-device speech engines built on [FluidAudio](https://github.com/FluidInference/FluidAudio): Parakeet TDT
0.6B (v3 multilingual, v2 English) for transcription with word timestamps, and FluidAudio's offline diarizer
(pyannote Community-1) for speaker labels. Both conform to the ChirpCore engine contracts (`SpeechEngine`,
`SpeakerDiarizing`, `ModelAssetManaging`) and run CoreML on the Neural Engine. No audio leaves the device, and the
only network traffic is the explicit model download from Hugging Face.

The code is ported from MacParakeet's `STTRuntime` and `DiarizationService` (upstream `upstream/macparakeet` @
`bbae9e0e`). Ported files carry a provenance header naming their upstream path.

## Entry point

`Registration.swift`: `FluidAudioEngines.makeDefault(settings:availableMemory:)` builds the `ParakeetEngine` for the
user's `ParakeetVariant` plus the `FluidAudioDiarizer`. Both use FluidAudio's default model cache and the shared
`ANEInferenceGate`; the app passes `ProcessAvailableMemory` for Parakeet's memory-fit check. Read `ModelAssetLifecycle.swift` next. It holds the lifecycle both engines share
(`downloadAssets` → `prepare` → `transcribe` / `diarize` → `deleteAssets`) and the rules for what may overlap.
Then read `ParakeetEngine.swift`.

## What's here

- `ModelAssetLifecycle.swift`: the generic actor both engines delegate to. It owns the download and load jobs
  (concurrent callers join one of each), the leases that in-flight jobs hold, and a generation counter. A delete
  refuses while a lease is out, bumps the generation, cancels and awaits in-flight work, and only then removes
  files. A load that finishes for an older generation is discarded. The FluidAudio calls come in through
  `Hooks`, which is also the test seam. A download first checks the network path (only when files are missing)
  and fails at once without one. It then retries transient failures up to 3 times, after 2 s, 8 s and 20 s, and
  stops at once when cancelled. `unload()` also refuses while an `acquire()` is in flight, tracked by
  `pendingAcquires`, not only while its lease is held (review N5): otherwise a route change's unload could land in
  the narrow window between a shared load finishing and the acquiring caller's own resumption (a handful of
  scheduler hops through `awaitSharedTask`'s relay task in `SharedTaskWait.swift`), and that caller would see
  `modelNotDownloaded` for a model that is on disk. `afterPrepareForTesting` is a test-only seam that lands a test
  deterministically in that window instead of racing real scheduling. `Hooks.beforeLoad` (fix/speech-memory-fit)
  runs right before a new load starts, never for a caller joining one; when it throws, no load starts and the
  error reaches the caller unchanged. Parakeet uses it for its memory fit; the diarizer and VAD leave it empty.
- `DownloadNetworkPolicy.swift`: the retry backoff, the injectable sleep and the pre-flight path check
  (`NWPathMonitor`'s first update, 2 s timeout; no answer lets the download try). Tests inject a policy that never
  waits and never reads the real network. FluidAudio owns its `URLSession`, so `waitsForConnectivity` and a
  background session are not available.
- `ParakeetEngine.swift`: the `SpeechEngine` actor. It downloads with `AsrModels.download` and loads with
  `AsrModels.loadLocal`, which reads local files only. Each `transcribe` checks out its own `AsrManager` (a
  `ParakeetWorker`) from an idle pool; all of them share one read-only `AsrModels`. A manager whose transcription
  threw or was cancelled is dropped, never returned to the pool. It transcribes a 16 kHz mono file with a fresh
  `TdtDecoderState` inside the gate, forwards that manager's chunk progress for files longer than 15 s, and maps a
  BCP-47 `languageHint` onto FluidAudio's v3 script filter. M2: a `.dictation`-purpose call decodes a clip that still
  fits one model window into memory and appends 0.5 s of silence (`paddedDictationSamples`, upstream issue #562);
  `transcribePreview` runs one in-memory preview window; `makeLiveSession` (`LiveSpeechSessionProviding`) returns a
  `TailWindowPreviewSession`, or nil without the model. Memory fit (fix/speech-memory-fit): before a new load,
  `SpeechEngineCapabilityRegistry.checkMemoryFit` compares its registry row's `memoryToLoadBytes` (0.8 GB) with the
  injected `AvailableMemoryReading` and throws `SpeechEngineError.insufficientMemory` instead of loading
  (`ParakeetMemoryFitTests`).
- The M2 live preview, `TailWindowPreviewSession`, moved to ChirpCore in M7 (plan 016) so any engine can use it;
  Parakeet still builds its sessions with it.
- `SharedTaskWait.swift`: `awaitSharedTask`, a cancellable wait on a shared task (the model load), so a cancelled
  job stops waiting at once while the load goes on for others.
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
- `FluidAudioModelLocations.swift`: model folders under the FluidAudio models root, cache-completeness checks,
  backup exclusion and on-disk size. "Ready" means complete: every required `.mlmodelc` has its root
  `coremldata.bin` and no `*.partial` file from an interrupted download, the Parakeet vocabulary (written last)
  exists, and FluidAudio's pinned-revision marker matches. `AsrModels.modelsExist` only checks that bundle folders
  exist, so when it passes on a partial cache the Parakeet download first runs `ModelHub.download`, which fetches
  the missing files and resumes the partial ones without deleting anything.
- `ModelDownloadTracker.swift`: maps FluidAudio's `DownloadProgress` phases onto one monotonic 0…1 bar, keeps the
  in-flight fraction, the last failure, the last phase and the attempt count for `assetStatus()`, and maps errors
  onto `SpeechEngineError`. A failed download reads as the owner-facing sentence, then
  `Details: <code>, host <host>, phase <phase>, <n> attempts.` The same text goes to `failed(message:)` and to the
  thrown `SpeechEngineError.underlying`, so Settings and `smoke-result.json` both show it. `DownloadRetry` decides
  what is transient: URL errors `timedOut`, `networkConnectionLost`, `notConnectedToInternet`,
  `cannotConnectToHost`, `cannotFindHost`, `dnsLookupFailed` (directly or as an underlying error) and FluidAudio's
  `DownloadError.stalled` and `.rateLimited`.

- `FluidAudioVoiceActivity.swift` (M3): Silero VAD (`VadManager`, **CPU only**, so the Neural Engine stays free
  for Parakeet) behind `ChirpCore.VoiceActivityDetecting`: `assetStatus` checks
  `<models root>/<Repo.vad.folderName>/silero-vad-unified-256ms-v6.2.1.mlmodelc`, `downloadAssets` fetches it
  (about 2 MB; only when the person taps Download in Settings → Meetings), `makeStream` never downloads and hands
  out a per-recording `FluidAudioVoiceActivityStream` (streaming state, upstream `fluidConfig`: 0.5 s silence,
  0.15 s padding). `FluidAudioEngines.makeVoiceActivity()` builds it.

## What to know before editing

- **FluidAudio is pinned exactly** (`exact: "0.16.1"` in `ChirpKit/Package.swift`). Bump it deliberately, never
  with a range. On every bump, diff the public API used here (`AsrModels`, `AsrManager`, `ASRConfig`,
  `TdtDecoderState`, `OfflineDiarizerModels`, `OfflineDiarizerManager`, `OfflineDiarizerConfig`, `ModelHub`,
  `Repo.revision`, `DownloadProgress`). Re-check `ModelDownloadTracker.fluidAudioDownloadWeight` against
  FluidAudio's `ProgressReporter`, the `.fluidaudio-revision` marker logic against its
  `ModelCache.matchesRevision`, `FluidAudioModelLocations.incompleteFiles` against its
  `ModelCache.incompleteFiles`, and `DownloadRetry` against its `DownloadError` cases and `RetryPolicy`. Then run the gated real-model test below as the regression pass. A revision
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
- **Blocking work is `@concurrent`.** CoreML compiles (`ParakeetEngine.loadRuntime`,
  `FluidAudioDiarizer.loadLocalModels`), file work (`ModelAssetLifecycle.offActor`, PLDA repair), the download
  retry loop and the chunk-progress setup are marked `@concurrent`, so they stay off the engine actors even if
  nonisolated async functions later default to the caller's actor (Xcode's "Approachable Concurrency"). Mark new
  blocking async work the same way.
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

This runs the package build, the unit tests and the strict lint. The unit tests never download and never wait
on a real network: they cover the gate, the descriptors, word timing, the not-downloaded and partial-cache paths,
the lifecycle race rules, download retries, the offline check and failure details, the per-job manager pool,
diarizer renumbering, PLDA repair and decoding, progress mapping, and Parakeet's memory-fit refusal.

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
