# ChirpEngineAppleSpeech

Apple's on-device speech recognition (iOS 26 `SpeechTranscriber` through `SpeechAnalyzer`) behind ChirpCore's
`SpeechEngine` (M7 Step 2, [plan 016](../../../docs/plans/2026-09-22-016-m7-engine-breadth.md)). Engine id
`apple.speech-transcriber`, locality on-device. Contract:
[`spec/contracts/speech-engine-plugin-v1.md`](../../../spec/contracts/speech-engine-plugin-v1.md).

## Entry point

`Registration.swift`: `AppleSpeechEngines.makeDefault(locale:)` returns the `AppleSpeechEngine`, in this device's
language. The app registers it in `SpeechEngineRouter` (`App/Sources/SpeechEngines/AppSpeechEngines.swift`).

## What's here

- `AppleSpeechEngine.swift`: the `SpeechEngine`, `SpeechEngineAvailabilityReporting` and
  `SpeechEnginePermissionReporting` actor.
  - **Status:** `assetStatus` maps `AssetInventory.status` (`installed` → ready, `supported` → not downloaded). It
    returns `.failed` with a sentence when `SpeechTranscriber.isAvailable` is false (the Simulator) or the language
    is not supported. Review M10: an installed model reads as not downloaded until Speech Recognition has been asked
    (Download asks), and as `.failed` with where to allow it when it was refused.
  - **Download and delete:** `downloadAssets` asks for the locale with `assetInstallationRequest`, which also
    reserves it for this app. `deleteAssets` releases the reservation.
  - **Transcribe:** `prepare` and `transcribe` never download and never ask for permission, so no prompt appears
    from a background file, a dictation or a live preview. They throw `modelNotDownloaded` while the model is missing
    or iOS has never asked, and the permission sentence when it was refused. `needsPermissionPrompt()` lets the DEBUG
    device benchmark skip Apple Speech (`permission-needed`) instead of waiting on a prompt.
  - **Result:** `makeResult` joins the final results and maps word runs to milliseconds, with non-decreasing starts,
    `endMs >= startMs` and confidence clamped to 0…1 (1 when missing). Empty text throws `emptyTranscript`.
  - `MonotonicProgress` keeps progress in 0…1 and never lets it go backwards.
- `AppleSpeechBackend.swift`: the test seam (`AppleSpeechBackend`, asset state, authorization, word and segment
  values).
- `LiveAppleSpeechBackend.swift`: the backend on the real framework.
  - It uses one `SpeechTranscriber` per job, with `audioTimeRange` and `transcriptionConfidence`.
  - `SpeechAnalyzer.analyzeSequence(from:)` runs over the normalized WAV, then `finalizeAndFinish(through:)`.
    Cancellation calls `cancelAndFinishNow()`.
  - Only final results are kept.
  - Download progress is read from `AssetInstallationRequest.progress`.

## What to know before editing

- **The Simulator has no SpeechTranscriber.** Settings lists Apple Speech as unavailable there, with the reason.
  Anything about real transcription is proven on the iPhone (the controller's device checks) or on a Mac with
  macOS 26 (`CHIRP_APPLE_SPEECH_TESTS=1`).
- **Permission.** iOS gates speech recognition behind the Speech Recognition permission. The app's Info.plist
  carries `NSSpeechRecognitionUsageDescription` (`project.yml`). No entitlement or capability is involved. macOS does
  not enforce this permission for `SpeechTranscriber` (checked with a command-line probe), so the Mac backend skips it.
- **No Neural Engine gate.** Inference runs in iOS's speech service, outside the app, so the app's memory barely
  grows and `ANEInferenceGate` does not apply.
- Not built yet: `DictationTranscriber` and custom vocabulary (`AnalysisContext` contextual strings), and native
  streaming for the live route. The router previews Apple Speech through the tail window instead.

## Tests

- `AppleSpeechEngineTests`: a fake backend checks the descriptor against its registry row, the Simulator's "not
  available", no implicit download, monotonic download progress, a single permission request, delete releases the
  reservation, word mapping and clamping, `emptyTranscript`, the language hint, a refused permission and prompt
  cancellation; review M10: an installed model without permission is not ready and a job never asks, only Download
  does; a refused permission shows in the status.
- `AppleSpeechEngineIntegrationTests`: opt-in with `CHIRP_APPLE_SPEECH_TESTS=1`. It runs the real engine on a `say`
  recording on a Mac with macOS 26, and skips where `SpeechTranscriber` is unavailable.
