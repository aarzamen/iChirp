# Speech Engine Plug-in v1

> Status: ACTIVE — the `ChirpCore` engine protocols and the behavior every engine target must honor.
> Decision: [ADR-004](../adr/004-engine-plugin-architecture.md). Narrative: [spec/06](../06-speech-engines.md).

## Purpose

Let speech engines and diarizers be added, swapped or removed without touching the pipeline, view models or
screens, and let later language and structure models follow the same pattern. The pipeline trusts these semantics;
an engine that breaks them corrupts transcripts silently.

## Producers

- `ChirpKit/Sources/ChirpCore/Engines/` — `EngineDescriptor.swift`, `ModelAssets.swift`, `SpeechEngine.swift`,
  `LanguageModel.swift`, `StructureModel.swift`, `EngineCatalog.swift` (`PrivacyRoutingPolicy`).
- Engine targets implementing them: `ChirpEngineFluidAudio` (`ParakeetEngine`, `FluidAudioDiarizer`) in M1; every
  future `ChirpEngine<Provider>` target.

## Consumers

- `ChirpFeatures`: `FileTranscriptionPipeline` (M1), `SpeechSettingsViewModel` (download/delete/status), later the
  dictation and meeting coordinators.
- `App/`: `AppEnvironment` (the only place that constructs engines) and the DEBUG smoke runner.
- Test fakes in `ChirpFeaturesTests` (`FakeSpeech`, `FakeDiarizer`), which must behave like a conforming engine.

## Stable fields and semantics

**`EngineDescriptor`**
- `id` is a stable, reverse-dotted string persisted in `Transcription.engine` (e.g. `fluidaudio.parakeet-tdt`,
  `fluidaudio.offline-diarizer`). Never reuse or rename an id; a different model family gets a new id, a different
  build of the same family is an `engineVariant`.
- `kind` ∈ `speech` · `diarization` · `language` · `structure`; `locality` ∈ `onDevice` · `localNetwork` · `cloud`.
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
  - Task cancellation is honored promptly and surfaces as `CancellationError` or `SpeechEngineError.cancelled`.
  - Result: `text` (the engine's text, unmodified), `words` (`WordTimestamp` in milliseconds from the start of the
    file, non-decreasing `startMs`, `endMs >= startMs`, confidence 0…1, `speakerId` nil), `language` (BCP-47 or nil;
    do not guess), `engineID` (= `descriptor.id`), `engineVariant` (e.g. `v3`).
  - Progress values are in 0…1 and never decrease.
- Core ML engines run every inference inside `ANEInferenceGate`.
- Conformers are `Sendable` (actors in practice); single-threaded C runtimes are confined to one actor.

**`SpeakerDiarizing`**
- `diarize(fileAt:)` takes the same normalized WAV and returns `DiarizationOutput`:
  - `segments` sorted chronologically, with ids renumbered `S1`…`Sn` in order of first speech;
  - `speakers` with the same ids and labels `Speaker 1`…`Speaker n`.
- "No speech detected" returns empty output, not an error. Any thrown error is treated as non-fatal by the pipeline.

**Routing**
- Before any engine processes an item, callers check `PrivacyRoutingPolicy.allows(_:for:host:userOverride:)`
  ([ADR-002](../adr/002-local-first-and-privacy-classes.md)). Engines do not enforce privacy themselves.

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
- `ParakeetEngineIntegrationTests` (gated by `CHIRP_MODEL_TESTS=1`: real transcription, monotonic timestamps,
  diarization returns at least one speaker).
- `FileTranscriptionPipelineTests.testMissingModelFailsWithActionableMessage` and
  `testDiarizationFailureIsNonFatal` (the pipeline's reliance on these semantics).

## When this changes

Update this contract, [spec/06](../06-speech-engines.md), the `ChirpCore` README, every conformer and test fake,
and the focused tests above in the same commit. A new engine target also updates
[`THIRD_PARTY_LICENSES.md`](../../THIRD_PARTY_LICENSES.md) and, if its license conflicts with GPL-3.0,
follows [ADR-010](../adr/010-plugin-license-gate.md).
