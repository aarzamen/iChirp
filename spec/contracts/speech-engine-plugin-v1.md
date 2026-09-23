# Speech Engine Plug-in v1

> Status: ACTIVE — the `ChirpCore` engine protocols and the behavior every engine target must honor.
> Decision: [ADR-004](../adr/004-engine-plugin-architecture.md). Narrative: [spec/06](../06-speech-engines.md).

## Purpose

Let speech engines and diarizers be added, swapped or removed without touching the pipeline, view models or
screens, and let later language and structure models follow the same pattern. The pipeline trusts these semantics;
an engine that breaks them corrupts transcripts silently.

## Producers

- `ChirpKit/Sources/ChirpCore/Engines/` — `EngineDescriptor.swift`, `ModelAssets.swift`, `SpeechEngine.swift`,
  `LiveSpeechSession.swift` (M2), `TailWindowPreviewSession.swift` (M2, in ChirpCore since M7),
  `SpeechEngineCapabilities.swift` and `SpeechEngineRouter.swift` (M7), `LanguageModel.swift`, `StructureModel.swift`,
  `EngineCatalog.swift` (`PrivacyRoutingPolicy`).
- Engine targets implementing them: `ChirpEngineFluidAudio` (`ParakeetEngine`, `FluidAudioDiarizer`) in M1;
  `ChirpEngineAppleSpeech` (`AppleSpeechEngine`) and `ChirpEngineWhisperKit` (`WhisperKitEngine`, one per variant) in M7;
  `ParakeetEngine` is also a `LiveSpeechSessionProviding` since M2 (tail-window preview); every future
  `ChirpEngine<Provider>` target.

## Consumers

- `ChirpFeatures`: `FileTranscriptionPipeline` (M1), `SpeechSettingsViewModel` (download/delete/status), the M2
  `DictationCoordinator` (live session for display, then `transcribe` with purpose `.dictation`), later the
  meeting coordinator.
- `App/`: `AppEnvironment` (the only place that constructs engines) and the DEBUG smoke runner.
- Test fakes in `ChirpFeaturesTests` (`FakeSpeech`, `FakeDiarizer`), which must behave like a conforming engine.

## Stable fields and semantics

**`EngineDescriptor`**
- `id` is a stable, reverse-dotted string persisted in `Transcription.engine` (e.g. `fluidaudio.parakeet-tdt`,
  `fluidaudio.offline-diarizer`). Never reuse or rename an id; a different model family gets a new id, a different
  build of the same family is an `engineVariant`.
- `kind` ∈ `speech` · `diarization` · `language` · `structure` · `voiceActivity` (M3, additive: Silero VAD for
  meeting live chunks, `ChirpCore.VoiceActivityDetecting`); `locality` ∈ `onDevice` · `localNetwork` · `cloud`.
- `license` names the model weights' license (and the SDK's when useful); never empty.
- `supportedLanguages` are BCP-47 tags; empty means unknown.

**`ModelAssetManaging`**
- `assetStatus()` never touches the network and never downloads. It returns `notDownloaded`,
  `downloading(fraction:)`, `ready(bytesOnDisk:)` or `failed(message:)`.
- `downloadAssets(progress:)` is the **only** method that downloads. Progress values are in 0…1 and never decrease.
  Downloaded folders are marked excluded from backup.
- `deleteAssets()` removes only the engine's own model files, never user data.

**`SpeechEngine`**
- `prepare()` is idempotent: calling it again after success is cheap and changes nothing.
- `transcribe(fileAt:options:progress:)`:
  - Input is a 16 kHz mono PCM WAV (the `AudioNormalizing` output). Engines must not require any other format.
  - If assets are missing it throws `SpeechEngineError.modelNotDownloaded(<engine id>)`; it **never downloads**.
  - Empty recognized text throws `SpeechEngineError.emptyTranscript`.
  - Task cancellation is honored promptly and surfaces as `CancellationError` or `SpeechEngineError.cancelled`. That
    includes a call that is still waiting: for an engine's one-call-at-a-time permit or for a model load another
    caller started. The waiter leaves at once; the running call and the shared load go on for the others.
  - Result: `text` (the engine's text, unmodified), `words` (`WordTimestamp` in milliseconds from the start of the
    file, non-decreasing `startMs`, `endMs >= startMs`, confidence 0…1, `speakerId` nil), `language` (BCP-47 or nil;
    do not guess), `engineID` (= `descriptor.id`), `engineVariant` (e.g. `v3`).
  - Progress values are in 0…1 and never decrease.
  - `options.purpose` (M2, additive, default `.file`) says what the text is for. An engine may tune for `.dictation`
    (Parakeet appends 0.5 s of trailing silence to a clip that still fits one model window, decoded in memory; the
    recorded file is never changed), but the result's shape and every rule above stay the same.
- FluidAudio's Core ML engines run every inference inside `ANEInferenceGate`. The gate is internal to
  `ChirpEngineFluidAudio` and does not serialize on iOS 26. WhisperKit (M7) serializes calls on its own pipeline
  instead, with a cancellable FIFO permit. Apple Speech runs in iOS's speech service.
- `SpeechEngineUnloading` (M7, optional): `unloadModels()` drops a loaded model, and the next `prepare` loads it again
  from disk. It is refused silently while a job holds the model (and, for WhisperKit, while a load runs). Callers: the
  benchmark between engines, and `SpeechEngineRouter.releaseUnroutedModels()` for an engine a route change left on
  no route.
- Conformers are `Sendable` (actors in practice); single-threaded C runtimes are confined to one actor.

**`SpeakerDiarizing`**
- `diarize(fileAt:)` takes the same normalized WAV and returns `DiarizationOutput`:
  - `segments` sorted chronologically, with ids renumbered `S1`…`Sn` in order of first speech;
  - `speakers` with the same ids and labels `Speaker 1`…`Speaker n`.
- "No speech detected" returns empty output, not an error. Any thrown error is treated as non-fatal by the pipeline.

**`LiveSpeechSession` / `LiveSpeechSessionProviding`** (M2, additive)
- `makeLiveSession(scheduler:options:)` returns a running session, or nil when the engine cannot preview now (no
  model on disk); it **never downloads**. Engines without a live mode simply do not conform.
- The session takes 16 kHz mono samples in order (`append`) and publishes hypothesis texts on `updates`. A
  tail-window engine's text covers its recent window; a streaming engine's is a cumulative partial. Callers
  stabilize them for display (`ChirpText.LiveTranscriptStabilizer`).
- **Display-only.** No live text is ever copied, pasted or saved; the kept text comes from `transcribe(fileAt:…)`
  over the recorded file. A test pins this (`DictationCoordinatorTests`).
- Every pass runs through the given `SpeechJobScheduler` on `.dictation` (the interactive slot), at most one at a
  time: a pass is skipped, never queued, while another runs.
- `finish()` / `cancel()` stop taking audio, cancel and **await** the work in flight, and end `updates`. After it
  returns nothing of the session runs, so the final pass gets the engine at once.
- Failed passes are dropped (display-only); they never fail the recording.
- This is the seam for M7 streaming engines (Nemotron, Parakeet EOU): a coordinator never special-cases an engine.

**Routing**
- Before any engine processes an item, callers check `PrivacyRoutingPolicy.allows(_:for:host:userOverride:)`
  ([ADR-002](../adr/002-local-first-and-privacy-classes.md)). Engines do not enforce privacy themselves.

**Live and final routes** (M7, additive; `SpeechEngineRouter.swift`, `SpeechEngineCapabilities.swift`)
- `SpeechEngineCapabilityRegistry` has one row per engine build, keyed by `(descriptor id, variant)`. A new engine adds
  its row, and its test pins the descriptor (id, word timestamps) to that row.
- `SpeechEngineRouter` is a `SpeechEngine` and a `LiveSpeechSessionProviding` that stands for the engine chosen on each
  route. `.live` gives display-only text: the dictation preview and a meeting's live text. `.final` gives every kept
  transcript.
- Consumers call `SpeechRouting.resolve(_:for:)` **once, when the job is queued**. They check privacy routing against
  the resolved engine's descriptor and store its id. A router's `descriptor` is its current final engine; nothing
  should read it mid-job.
- A live engine without `LiveSpeechSessionProviding` is previewed with `TailWindowPreviewSession`. Each pass writes the
  window to a temporary 16 kHz WAV, transcribes it with purpose `.dictation`, and deletes it.
- A meeting holds a `SpeechEngineLease` from start until it finishes. `select` throws `meetingInProgress` while any
  lease is out.
- **Memory across routes** (review I3). A dictation or a meeting keeps the live and final engines loaded together, so
  two different engines must fit `SpeechEngineCapabilityRegistry.memoryBudgetBytes` (2.5 GB) together, by the
  registry's runtime estimates. A final choice that does not fit moves the live route to the same engine (its tail
  preview; `select` returns both routes), a live choice that does not fit throws `combinedMemoryOverBudget`, and a
  saved pair over the budget starts with live on the final engine. After a change, `releaseUnroutedModels()` unloads
  every engine on neither route. With today's rows every pair fits (Parakeet 0.8 + Turbo 1.5 GB); the iPhone
  benchmark must measure two engines loaded together before the estimates are trusted.
- **A route whose model is missing** (review I2): a restored backup keeps `ichirp.speechRoutes` but not the Whisper
  folders, and iOS can remove an Apple Speech asset. Consumers check the resolved engine's `assetStatus()` and fail
  with a message that names that engine and says to download it in Settings → Speech engines or switch the route to
  Parakeet (`ChirpFeatures.SpeechModelMissingError`); they never tell the person to download Parakeet when Parakeet
  is not the engine. Settings → Speech engines never deletes an engine a route uses while a lease is out, and moves
  such routes back to Parakeet before deleting.
- `SpeechEngineAvailabilityReporting` (optional) lets an engine say it cannot run on this device. Settings lists it
  with the reason and never downloads it.

**Target rule**
- An engine target depends only on `ChirpCore` plus its SDK and exposes one registration entry point (M1:
  `FluidAudioEngines.makeDefault(settings:)`). No other target imports the SDK.

## Non-stable fields

- `displayName`, `provider` wording, `approximateDownloadBytes` values.
- Internal tuning (`ChirpTuning.parakeetParallelChunks`), model folder locations, log messages.
- The exact text of `failed(message:)` and `underlying(String)` errors, as long as it stays actionable.

## Versioning and compatibility

Adding a protocol requirement with a default implementation, a new optional field, or a new `EngineKind` /
`EngineLocality` case (with every `switch` updated) is additive. Removing or retyping a requirement, changing the
input audio format, or changing id semantics is breaking: write `speech-engine-plugin-v2.md`, migrate every
conformer and fake in the same change, and keep persisted `engine` ids readable.

## Tests that enforce this

- `PrivacyRoutingPolicyTests` (ChirpCoreTests): `testClinicalAllowsOnDevice`,
  `testClinicalDeniesCloudWithoutOverrideAndAllowsItWithOverride`,
  `testClinicalLocalNetworkRequiresTrustedHostOrOverride`, `testGeneralAndPersonalAreAllowedEverywhere`.
- `ParakeetEngineDescriptorTests` (id, kind, locality, non-empty license).
- `ParakeetEngineNotDownloadedTests` (`assetStatus() == .notDownloaded`; `transcribe` throws `modelNotDownloaded`).
- `WordTimingParityTests` (engine-internal word builder equals ChirpText's).
- `ANEInferenceGateTests` (ported from upstream).
- `SpeechEngineRouterTests` and `SpeechEngineCapabilityRegistryTests` (ChirpCoreTests): separate routes, snapshot at
  enqueue, lease blocks a switch, not-in-build refusal, tail preview over a deleted temporary WAV, no session without
  the model, forgiving decoding, the memory budget; review I3: `testAnEngineIsUnloadedOnceItIsOnNoRouteAndNotBefore`,
  `testAPairOverTheMemoryBudgetKeepsOneModelResident`, `testTheDefaultBudgetAllowsEveryPairThisBuildOffers`,
  `testASavedPairOverTheBudgetPreviewsWithTheFinalEngine`. `SpeechRouteConsumersTests` (ChirpFeaturesTests): files and
  meetings use the final route, a queued file keeps its engine, a meeting holds and releases the lease; review I2: a
  file, a dictation and a meeting name the routed engine whose model is missing, and Retry works after switching.
  `SpeechEnginesViewModelTests`: deleting a routed engine is refused during a meeting and otherwise moves its routes
  to Parakeet with a notice; a route change unloads the engine that left both routes.
- `TailWindowPreviewSessionTests` (ChirpCoreTests since M7; single-flight, 15 s window, skip without new audio, cancel-and-drain on finish,
  interactive slot) and `ParakeetDictationPadTests` (0.5 s pad only when the padded clip fits one window; the
  `.dictation` purpose uses it, `.file` never does).
- `ModelAssetLifecycleTests.testACancelledWaiterStopsWaitingWhileTheSharedLoadContinues`, and for WhisperKit
  `WhisperKitEngineTests.testACallQueuedBehindARunningCallStopsPromptlyWhenCancelledWhileTheFirstKeepsRunning`,
  `testACancelledWaiterForTheSharedLoadStopsWaitingWhileTheLoadContinues` and
  `testALivePreviewPassWaitingBehindAFileJobEndsPromptlyWhenTheDictationStops`.
- `ParakeetEngineIntegrationTests` (gated by `CHIRP_MODEL_TESTS=1`: real transcription, monotonic timestamps,
  diarization returns at least one speaker).
- `FileTranscriptionPipelineTests.testMissingModelFailsWithActionableMessage` and
  `testDiarizationFailureIsNonFatal` (the pipeline's reliance on these semantics).

## When this changes

Update this contract, [spec/06](../06-speech-engines.md), the `ChirpCore` README, every conformer and test fake,
and the focused tests above in the same commit. A new engine target also updates
[`THIRD_PARTY_LICENSES.md`](../../THIRD_PARTY_LICENSES.md) and, if its license conflicts with GPL-3.0,
follows [ADR-010](../adr/010-plugin-license-gate.md).
