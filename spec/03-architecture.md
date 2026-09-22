# 03 - Architecture

> Status: ACTIVE — module map, dependency rules and data flow for M1; later milestones add modules without
> changing these rules.

## Shape

```
┌─────────────────────────── iChirp app target (App/) ───────────────────────────┐
│ iChirpApp → AppEnvironment (composition root: builds concrete stores/engines)  │
│ Screens: RootTabView · Capture · Library · Transcript (+PlayerBar) · Settings  │
│          · Transforms · NotBuiltYetSheet · DEBUG SmokeTestRunner               │
└───────────────┬────────────────────────────────────────────────────────────────┘
                │ imports ChirpKit products
┌───────────────▼──────────────── ChirpKit (local Swift package) ───────────────┐
│ ChirpUI ─────────► ChirpCore                                                    │
│ ChirpFeatures ───► ChirpCore, ChirpText, ChirpExport   (engines injected)       │
│ ChirpExport ─────► ChirpCore, ChirpText                                         │
│ ChirpText ───────► ChirpCore                                                    │
│ ChirpStore ──────► ChirpCore, GRDB                                              │
│ ChirpAudio ──────► ChirpCore (+ AVFoundation)                                   │
│ ChirpEngineFluidAudio ─► ChirpCore, FluidAudio (exact 0.16.1)                   │
│ ChirpCore ───────► Foundation, OSLog only                                       │
└────────────────────────────────────────────────────────────────────────────────┘
```

The authoritative graph is `ChirpKit/Package.swift`; the app's product list is in `project.yml`.

## Rules

1. **The app target is a composition root plus screens.** `AppEnvironment` is the only place that names concrete
   types (`GRDBTranscriptionStore`, `AVAudioNormalizer`, `ParakeetEngine`, …). Screens talk to view models.
2. **`ChirpCore` owns the contracts** (models, engine protocols, pipeline protocols, scheduler, paths, build
   identity) and depends on nothing heavy. Everything else codes against it.
3. **Engines are plug-ins.** `ChirpEngine<Provider>` targets depend only on `ChirpCore` plus their SDK. Nothing
   outside the engine target imports the SDK; `ChirpFeatures` receives engines as `any SpeechEngine` /
   `any SpeakerDiarizing`. See [`06-speech-engines.md`](06-speech-engines.md) and the
   [plug-in contract](contracts/speech-engine-plugin-v1.md).
4. **View models live in `ChirpFeatures`**, are `@MainActor @Observable`, and are tested on the Mac host with fakes
   for every protocol. SwiftUI views are not unit-tested; their logic lives in view models.
5. **Package tests run on the Mac** (`swift test --package-path ChirpKit`), so the package stays platform-neutral:
   iOS-only APIs (UIKit, `AVAudioSession`, `BGTaskScheduler`) stay in the app target or behind a protocol.
6. **Upstream is ported, not linked.** Nothing builds against `upstream/macparakeet/`.

## M1 data flow (file transcription)

```
Capture "Import audio"
  └─► TranscriptionJobCenter.start(fileAt:)                     (@MainActor, keeps the Task for cancel)
        └─► FileTranscriptionPipeline (actor)
              1 importFile: copy → media/<id>/source.<ext>; insert row (processing)
              2 AudioNormalizing.normalize → media/<id>/normalized-16k.wav
              3 SpeechJobScheduler.run(.fileTranscription) { SpeechEngine.transcribe(...) }
              4 SpeakerDiarizing.diarize (if enabled and ready) → SpeakerMerger → segments
              5 TextRefinement (Clean only) → TitleDeriver / SnippetDeriver
              6 TranscriptionStoring.savePreservingUserMetadata → delete normalized WAV
        progress callbacks ─► TranscriptionJobCenter.progress[id] ─► Capture/Library rows
Library / Transcript view models observe TranscriptionStoring.observeAll()
```

Every step mirrors upstream `TranscriptionService` (local-file entry, `transcribeAudio`, `completeTranscription`);
see the [pipeline map](../docs/research/2026-09-22-macparakeet-pipeline-map.md), section 3(b).

## Concurrency

- Swift 6 language mode, strict concurrency, zero warnings in first-party code.
- New I/O is async/await. No completion handlers or Combine in new code.
- When order or result matters, await it; do not hide ordered work in a fire-and-forget `Task`.
- Keep `@MainActor` work short. Decoding, inference, diarization and database writes run off the main actor.
- **One scheduler per process.** All speech inference goes through the shared `SpeechJobScheduler`: an interactive
  slot (dictation) and a background slot ordered meetingFinalize > meetingLiveChunk > fileTranscription, FIFO
  within a priority, never preempting a running job.
- **Every Core ML inference goes through `ANEInferenceGate`** (ported from upstream). On iOS it does not serialize,
  because iOS 26 shares the macOS 26 Core ML generation where upstream stopped serializing.
- Single-threaded C runtimes (Needle, llama.cpp) are wrapped in one actor each.

## Errors and logging

- Errors that reach the user are actionable ("Download the Parakeet speech model in Settings → Speech model"), and
  are stored on the row (`errorMessage`) with Retry.
- `Log.logger(<category>)` under subsystem `com.aarzamen.ichirp`. **Never log transcript text, audio paths that
  include user file names, or prompts**; log ids, stages, durations and error types.
- The build identity is logged once at launch.

## Where later milestones plug in

| Milestone | Adds | Rule it must keep |
|---|---|---|
| M1.5 | Share extension target, App Group, background task handler | Extension has no models; IDs derived at runtime (SideStore renames them) |
| M2 | Capture in `ChirpAudio`, live session protocol, App Intents, widget extension | Live text is display-only; the final pass is authoritative |
| M3 | Meeting recorder, recovery service | Crash-safe files; never delete a session without the user |
| M4 | `ChirpEngine<Provider>` language-model targets, templates, Keychain store | Privacy router in front of every generation |
| M6 | Structure-model targets (Needle behind a build flag) | Confidence gating; numbers re-validated in code |
| M7 | More speech engines, benchmark harness | Capability descriptors, not special cases in screens |
