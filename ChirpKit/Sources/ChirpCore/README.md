# ChirpCore

The contract layer of ChirpKit. Every other module (store, audio, engines, text, export, features, UI) codes
against the types and protocols here, and ChirpCore depends on nothing but Foundation and OSLog.

## Entry point

Start with `Models/Transcription.swift` (the library record) and `Engines/SpeechEngine.swift` (the engine
plug-in protocol). The pipeline in ChirpFeatures wires `AudioNormalizing` → `SpeechJobScheduler` →
`SpeechEngine` / `SpeakerDiarizing` → `TranscriptionStoring`, all declared here.

## What's here

- `Models/Transcript.swift`: word, speaker, diarization and transcript segment value types, ported from
  MacParakeet without the correction-only fields.
- `Models/Transcription.swift`: the `Transcription` record, with `displayTitle` and `displayText`. M3 adds
  `userNotes`, `isPartialAudio`, `audioRemovedAt` and `renameSpeaker(_:to:)` (roster and segment labels together);
  M5 adds `sourceURL`, `sourceTitle` (wins over the derived title), `documentFormat` and `documentPages`
  ([contract](../../../spec/contracts/document-items-v1.md)).
- `Models/Document.swift`: M5 `DocumentFormat` (pdf, txt, md, rtf, html, docx; from a file extension) and
  `DocumentPage` (page number, text, `textLayer` / `ocr` / `empty`), plus `Transcription.isDocument`.
- `Models/PrivacyClass.swift`: `general` / `personal` (default) / `clinical` sensitivity classes, ordered by
  `strictness`, with `stricter(_:)`.
- `Models/LanguageModelProvider.swift`: `LanguageModelProviderKind` (stable engine ids),
  `LanguageModelProviderConfiguration` (no secret; locality derived from the base URL's host; `validate()`),
  `LocalNetworkHost` (the conservative "is this host on the LAN" rule) and
  `PrivacyRoutingPolicy(trustingLocalNetworkHostsOf:)`.
- `Secrets/SecretStoring.swift`: `SecretValue` (a redacted in-memory secret) and `SecretStoring` (Keychain in the
  app via `ChirpKeychain`, a fake in tests).
- `Models/TranscriptionSettings.swift`: user preferences (`CleanupMode`, `ParakeetVariant`, speaker labels,
  filler removal, M3's `meetingAudioRetentionDays`, nil = keep forever), with forgiving decoding.
- `Engines/EngineDescriptor.swift`: `EngineDescriptor`, `EngineKind` and `EngineLocality`, the static facts
  about an engine.
- `Engines/ModelAssets.swift`: `ModelAssetStatus` and `ModelAssetManaging` (download, status, delete).
- `Engines/SpeechEngine.swift`: `SpeechEngine`, `SpeakerDiarizing`, their options (including the M2
  `SpeechTranscriptionPurpose`), results and `SpeechEngineError`.
- `Engines/LiveSpeechSession.swift`: `LiveSpeechSession` and `LiveSpeechSessionProviding` (M2): display-only live
  text, the seam for streaming engines (contract `spec/contracts/speech-engine-plugin-v1.md`).
- `Engines/SpeechSynthesis.swift`: `SpeechSynthesizing` (text to speech: "Listen", spoken answers, read-back),
  `SynthesisRequest`, `SynthesisVoice`, `SynthesizedAudio`, `SpeechSynthesisError`. Engine kind `.speechSynthesis`.
  Contract: `spec/contracts/speech-synthesis-plugin-v1.md`; conformers arrive in plan 020.
- `Engines/LanguageModel.swift`: the M4 text-generation contract (`LanguageModel` with `endpointHost`,
  `contextWindowTokens()`, `availability()` and `generate`; `GenerationRequest`, `GenerationEvent`,
  `GenerationUsage`, `LanguageModelAvailability`, `LanguageModelError`). Conformers: `ChirpEngineAppleFM`,
  `ChirpEngineHTTPLLM`. Contract: `spec/contracts/language-model-plugin-v1.md`.
- `Models/StructuredResult.swift` (M6): the evidence ledger's values (`StructuredRun`, `StructuredField` with its
  `StructuredSourceSpan` and `StructuredVerdict`, `StructuredEvalRun`) and `StructuredResultStoring`
  ([structured-results-v1](../../../spec/contracts/structured-results-v1.md)).
- `Engines/StructureModel.swift`: the M6 extraction and embedding contract (`StructuredOutput` with the model hash and
  `isAbstention`, `StructureModelError`); conformers `NeedleStructureModel` and the STUB
  ([structure-model-plugin-v1](../../../spec/contracts/structure-model-plugin-v1.md)).
- `Engines/EngineCatalog.swift`: `PrivacyRoutingPolicy`, which decides which engine localities may process
  each privacy class.
- `Pipeline/AudioNormalizing.swift`: the decode-to-16 kHz-mono contract and `NormalizedAudio`, including the M1.5
  `normalize(sourceURL:outputURL:audioTrackOrdinal:)` requirement (a default implementation keeps other
  normalizers compiling).
- `Pipeline/AudioTracks.swift`: `AudioTrackDescriptor` (zero-based ordinal, one-based `displayName`),
  `AudioTrackProbing` and `AudioTrackSelectionError` (M1.5; contract
  `spec/contracts/file-transcription-audio-tracks-v1.md`).
- `Pipeline/TranscriptionStoring.swift`: the persistence contract implemented by ChirpStore. M3 adds the
  field-level `updateUserNotes`, `renameSpeaker` and `markAudioRemoved`, with fetch-and-update defaults in a
  protocol extension so other conformers (fakes) keep compiling; real stores implement them atomically.
- `Pipeline/AudioCapturing.swift`: the M2 microphone-recording contract (`AudioCapturing`, `CaptureUpdate`,
  `CaptureEvent`, `RecordedAudio`, `MicrophonePermission`, `AudioCaptureError`) implemented by ChirpAudio's
  `DictationRecorder`, and `SpeechAudio` (16 kHz, the 0.3 s minimum).
- `Pipeline/MeetingAudioCapturing.swift` (M3): the meeting recorder contract (`start` into `meeting.caf`, pause
  writes nothing, mute writes silence, `stop` and `cancel` never delete audio), implemented by ChirpAudio's
  `MeetingRecorder`.
- `Pipeline/SpeechWAVFile.swift` (M3): a Foundation-only 16 kHz mono Float32 WAV writer for a meeting's temporary
  live-preview chunks.
- `Models/MeetingSession.swift` (M3): `MeetingSessionFiles` (`recording.lock`, `meeting.caf`, `chunks/`),
  `MeetingSessionState` (`recording`, `awaitingTranscription`), `MeetingSessionLock` (schema 1, `launchId` owner,
  captured route and privacy class, notes decoded on their own) and `MeetingAudioRetention`. Contract:
  `spec/contracts/meeting-session-v1.md`.
- `Engines/VoiceActivity.swift` (M3): `VoiceActivityDetecting` (a `ModelAssetManaging` plug-in with a window size
  that hands out a per-recording `VoiceActivityStream`, or nil when its model is not on disk), `VoiceActivityEvent`
  and `VoiceActivityConfig` (upstream 0.5 s silence, 0.15 s padding). `EngineKind.voiceActivity` is additive.
- `Scheduling/SpeechJobScheduler.swift`: the actor that serializes speech work into an interactive slot
  (dictation) and a prioritized background slot, with live-chunk backpressure.
- `System/AppPaths.swift`: the on-disk layout (`ichirp.sqlite`, `media/<uuid>/`) and relative-path mapping.
- `System/BuildIdentity.swift`: reads the build stamp (version, build, commit, branch, dirty, date) from
  Info.plist.
- `System/Log.swift`: `Log.logger(_:)` under the `com.aarzamen.ichirp` subsystem.

## What to know before editing

- The public signatures are contracts. Parallel lanes and later milestones compile against them. Adding
  a conformance or a defaulted parameter is safe. Renaming, retyping or adding a required parameter breaks
  other modules. Any change to the engine protocols (`SpeechEngine`, `SpeakerDiarizing`,
  `ModelAssetManaging`, `LanguageModel`, `StructureModel`, `EngineDescriptor`) must also update
  `spec/contracts/speech-engine-plugin-v1.md` (and, for `LanguageModel`, `SecretStoring` and the provider types,
  `spec/contracts/language-model-plugin-v1.md`) and its tests in the same change.
- Keep ChirpCore free of third-party dependencies and UI frameworks. Engine-specific code belongs in
  its own target, such as `ChirpEngineFluidAudio`.
- `Transcription` round-trips through a default `JSONEncoder`/`JSONDecoder`. New stored properties must be
  optional or defaulted, and new rows default to `PrivacyClass.personal`.
- `SpeechJobScheduler` invariants: a slot is released exactly once per granted job, every continuation is
  resumed exactly once, and a job leaves `pending` before its continuation is resumed. Keep the file
  warning-free under Swift 6 strict concurrency. Scheduling semantics follow upstream `STTScheduler`, but the
  code is new. Do not paste upstream code into it.
- `Models/Transcript.swift` is a port. Keep its provenance header, and diff against
  `upstream/macparakeet/Sources/MacParakeetCore/Models/Transcription.swift` when syncing upstream.
- `AppPaths.applicationSupport()` keeps the app root in backups because it holds user data. Only
  re-downloadable model folders are excluded from backup, and that happens where those folders are created.

## How to verify

```bash
cd /Users/ama/Documents/GitHub/iChirp
scripts/check.sh ChirpCoreTests
```

This runs the package build, the focused ChirpCore tests and the strict `swift format` lint. The scheduler
tests use timing, so after touching `SpeechJobScheduler.swift` run them repeatedly:

```bash
for i in $(seq 1 20); do swift test --package-path ChirpKit --filter SpeechJobSchedulerTests || break; done
```
