# ChirpEngineWhisperKit

OpenAI Whisper on Argmax's WhisperKit (Core ML) behind ChirpCore's `SpeechEngine` (M7 Step 4,
[plan 016](../../../docs/plans/2026-09-22-016-m7-engine-breadth.md)). Engine id `argmax.whisperkit`. The variants
are `base` and `large-v3-turbo`, and ids are forever. It runs on-device. The package is `argmax-oss-swift`, pinned
exact **1.1.0** (MIT), and only its `WhisperKit` product is linked. Contract:
[`spec/contracts/speech-engine-plugin-v1.md`](../../../spec/contracts/speech-engine-plugin-v1.md).

## Entry point

`Registration.swift`: `WhisperKitEngines.makeDefault(modelsDirectory:availableMemory:)` returns one
`WhisperKitEngine` per `WhisperKitVariant`. The app passes `<Application Support>/Models/WhisperKit` and
`ProcessAvailableMemory`, and registers each engine in `SpeechEngineRouter`
(`App/Sources/SpeechEngines/AppSpeechEngines.swift`).

## What's here

- `WhisperKitEngine.swift` (ports upstream `WhisperEngine`): the `SpeechEngine` and `SpeechEngineUnloading` actor.
  - **Files:** the model lives at `<dir>/models/argmaxinc/whisperkit-coreml/<folder>` and the tokenizer at
    `<dir>/models/openai/whisper-*`. A completion marker is written after a successful download. `assetStatus` is
    ready only when the marker, `tokenizer.json` and `tokenizer_config.json` are all present.
  - **Load:** `prepare` loads once and shares the load. It refuses (`modelNotDownloaded`) while files are missing,
    and never downloads. A caller cancelled while it waits for the load (a first-time Core ML compile can take
    minutes) stops waiting at once; the load goes on for the others (`SharedTaskWait.swift`, as Parakeet's).
    `unloadModels()` is refused while a load runs, so two pipelines are never loaded at once.
  - **Memory fit** (fix/speech-memory-fit): right before a load starts (not when a caller joins one, not while the
    model is loaded), `SpeechEngineCapabilityRegistry.checkMemoryFit` compares the row's `memoryToLoadBytes` (the
    first-load Core ML compile peak) with the injected `AvailableMemoryReading`. A load that does not fit throws
    `SpeechEngineError.insufficientMemory` and nothing is loaded: Turbo's first load was killed by iOS on an iPhone
    17 Pro when only its 1.5 GB runtime estimate was checked.
  - **Calls:** one call at a time on the loaded pipeline (`AsyncPermit`, FIFO). A call cancelled while it waits in
    line leaves at once with `CancellationError`, so a dictation's Stop or Cancel never waits behind a file job.
    Cancellation of the running call stops decoding through WhisperKit's callback.
  - **Delete:** refused while a call runs. Otherwise new loads are refused at once, a load or download in flight is
    waited for and its model released, and only then are the folders removed.
  - **Language:** a forced language that yields nothing is retried with detection (upstream).
  - **Words:** trimmed, in milliseconds, with non-decreasing starts and `endMs >= startMs`. The probability is
    clamped to 0…1.
  - `unloadModels()` frees the model; the benchmark does this between engines. `deleteAssets` removes only this
    variant's model and tokenizer folders.
- `WhisperKitBackend.swift`:
  - `WhisperKitVariant`: folder names, tokenizer repos, sizes.
  - The test seam: `WhisperKitBackend` and `WhisperKitTranscribing`, and the output values.
- `LiveWhisperKitBackend.swift`: the backend on WhisperKit.
  - **Download:** `WhisperKit.download(variant:downloadBase:)` fetches the model, and
    `ModelUtilities.loadTokenizer(for:tokenizerFolder:)` fetches the tokenizer into the same Hub layout. This is the
    only network use.
  - **Load:** the tokenizer is read from local files first (`AutoTokenizerWrapper.from(modelFolder:)`); a damaged
    one is refused (`WhisperKitLoadError.tokenizerUnreadable`, shown as "Delete it and download it again") because
    WhisperKit would otherwise fetch it from Hugging Face. Then `WhisperKitConfig` with `download: false`, the local
    model folder and the tokenizer folder.
  - **Transcribe:** VAD chunking with `.incremental` file loading, two concurrent windows, `skipSpecialTokens` and
    word timestamps. Progress is the share of the file decoded: the end of the last segment WhisperKit found (its
    `segmentDiscoveryCallback`, in file time) over the file's length, below 1 until the engine reports the end.
    WhisperKit's own `progress` restarts for every streamed window, so it is not used.
- `AsyncPermit.swift` and `SharedTaskWait.swift`: copies of ChirpEngineFluidAudio's cancellation-aware permit and
  shared-task wait (an engine target depends only on ChirpCore).

## What to know before editing

- **The tokenizer is not in the Core ML repo.** WhisperKit fetches it from `openai/whisper-*` when it is missing, so
  the download step fetches it and the files check requires it. Otherwise the first `prepare` would download without
  the person asking.
- **`WhisperKit` is not `Sendable`.** `LoadedWhisperKit` wraps it as `@unchecked Sendable`, and the engine's permit
  is what makes that true. Never call it from two tasks at once.
- **Memory.** The registry estimates the runtime memory (base about 0.3 GB, large-v3 turbo about 1.5 GB) and the
  first-load compile peak (placeholders: base 0.6 GB, turbo 3.5 GB, to be replaced by the device measurement). The
  DEBUG device benchmark records the memory available before each load and the peak during the load
  (`scripts/device_benchmark.sh`); replace the placeholders with those numbers. `concurrentWindows` is 2, not
  WhisperKit's default of 16, for the same reason.
- **No Neural Engine gate.** `ANEInferenceGate` belongs to `ChirpEngineFluidAudio` and does not serialize on iOS 26.
  The scheduler runs background jobs one at a time.
- **Bumping the package.** Follow the FluidAudio discipline in spec/06: read the release notes, change `exact:`, run
  `scripts/check.sh WhisperKitEngineTests`, then `CHIRP_WHISPER_TESTS=1` with both variants, and update
  THIRD_PARTY_LICENSES in the same commit.

## Tests

- `WhisperKitEngineTests` (fake backend):
  - descriptors against their registry rows, and stable variant ids;
  - nothing downloads or loads implicitly; monotonic download progress; a missing tokenizer (`tokenizer.json` or
    `tokenizer_config.json`) means not ready; a damaged tokenizer is refused at load, never fetched;
  - a failed download can be retried;
  - word mapping and clamping; the language fallback; `emptyTranscript`; prompt cancellation;
  - one call at a time with a single load; unload then reload; delete touches only its own variant; language codes;
  - review I1: a queued call cancelled behind a running one returns at once while the first keeps running; a
    cancelled waiter leaves the shared load while it continues; a dictation's live-preview pass queued behind a file
    job ends at once when the dictation stops (through `SpeechEngineRouter` and `TailWindowPreviewSession`);
  - review M3: an unload during a load starts no second load; a delete during a load waits for it and releases its
    model; review M1: progress is the share of audio covered, below 1 until the end;
  - fix/speech-memory-fit: `testALoadThatDoesNotFitTheMemoryIOSAllowsIsRefusedNamesBothNumbersAndLoadsNothing`
    (and Retry loads once there is room), `testALoadThatFitsProceedsAndALoadedModelIsNotCheckedAgain`,
    `testAnUnknownReadingDoesNotRefuse`.
- `WhisperKitEngineIntegrationTests`: opt-in with `CHIRP_WHISPER_TESTS=1`. It runs the real model on a `say`
  recording on the Mac, and checks that progress is real (a value between 0 and 1 before the final 1). `CHIRP_WHISPER_VARIANT=large-v3-turbo` picks the big one, and `CHIRP_WHISPER_MODELS_DIR`
  sets the models folder (default `~/Library/Caches/iChirpTests/WhisperKit`).
