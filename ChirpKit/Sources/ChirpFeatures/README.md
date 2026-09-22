# ChirpFeatures

The file-transcription pipeline coordinator and the `@MainActor @Observable` view models the app screens use.
Depends only on ChirpCore, ChirpText and ChirpExport: engines, the store and the normalizer arrive as ChirpCore
protocols, so nothing here imports FluidAudio, GRDB or AVFoundation, and every test runs on the Mac with fakes.

## Entry point

`FileTranscriptionPipeline.swift`, a port of the local-file path of upstream
`Services/TranscriptionService.swift` (`transcribe(fileURL:)` → `transcribeAudio` → `completeTranscription`). Read it
with the M1 data flow in `spec/03-architecture.md`. Then read `TranscriptionJobCenter.swift`, which owns the
pipeline's `Task`s and publishes its progress to the UI.

## What's here

- `FileTranscriptionPipeline.swift`: the `FileTranscriptionPipeline` actor plus `PipelineStage` and `JobProgress`.
  - `importFile(from:sourceType:)` copies the file (security-scoped, never moved) into `media/<id>/source.<ext>` on
    the pipeline's file queue, then inserts a `.processing` row.
  - `process(id:)` runs: privacy routing check → model check → audio-preparation permit (at most two jobs) →
    normalize to
    `media/<id>/normalized-16k.wav` → one scheduler
    `.fileTranscription` job (`prepare`, `transcribe`, then `diarize` if enabled and ready) → `SpeakerMerger` →
    `TextRefinement` → `TitleDeriver` / `SnippetDeriver` → `FileTranscriptSegments` → `savePreservingUserMetadata`.
  - `retry(id:)` moves a `.failed` / `.cancelled` / `.interrupted` row back to `.processing` and runs `process`
    again from the stored source.
  - `sweepOrphanedTemporaryAudio()` deletes `normalized-16k.wav` files left by a killed process (call at launch).
- `TranscriptionJobCenter.swift`: the running jobs. `start(fileAt:pipeline:)` does import and process in one tracked
  `Task`, and `retry` and `cancel` act by transcription id. `progress[id]` feeds "Transcribing · NN%", and
  `lastImportError` is set when a file could not even be imported (`dismissImportError()` clears it).
  `progressHandler` is the pipeline's `onProgress`.
- `LibraryViewModel.swift`: all rows from `observeAll()`, filter chips, search, "Today" / "Yesterday" / "MMM d"
  sections, delete (row plus its `media/<id>/` folder and any `ExportTempFiles` export folder for it), favorite, and
  `loadError` / `dismissLoadError()`.
- `TranscriptViewModel.swift`: one row. Paragraphs come from `TranscriptParagraphBuilder`; without words there is one
  `displayText` paragraph. Also speaker labels, `mediaURL` for the player, `plainText` for Copy, `exportFile` into
  `<tmp>/export-<id>/`, rename and favorite.
- `SpeechSettingsViewModel.swift`: the speech and diarizer model status, download with progress, delete (the
  engine's "in use" refusal lands in `lastError`, cleared by `dismissError()`), and `settingsValue`, which saves on
  every set.
- `CaptureViewModel.swift`: the three newest rows for Capture's "Recent".
- `SettingsStore.swift`: `SettingsStoring` and `UserDefaultsSettingsStore`, a JSON blob under
  `ichirp.transcriptionSettings` that falls back to the defaults when missing or unreadable.

## Wiring (app composition root)

```swift
let jobs = TranscriptionJobCenter()
let pipeline = FileTranscriptionPipeline(
    paths: paths, store: store, normalizer: normalizer, speech: engines.speech, diarizer: engines.diarizer,
    scheduler: scheduler, settings: settings, onProgress: jobs.progressHandler)
_ = try await store.markStaleProcessingAsInterrupted()     // at launch, then:
await pipeline.sweepOrphanedTemporaryAudio()
jobs.start(fileAt: pickedURL, pipeline: pipeline)          // per imported file
LibraryViewModel(store: store, paths: paths)               // paths: delete removes media/<id>/ too
```

## What to know before editing

- **Privacy routing runs before any engine gets audio** (ADR-002, `spec/12-privacy.md`). `run` asks
  `PrivacyRoutingPolicy` (injected, default: no trusted LAN hosts) whether the speech engine's locality may process
  the item's `privacyClass`, first at the start of the job, so refused audio is never even prepared, and again
  inside the scheduler slot against the class as stored at that moment, because the user may change it while the
  job waits. A refused speech engine fails the row with `PipelineError.privacyRoutingRefused`; a refused diarizer is
  skipped and logged (speaker labels are optional). On-device engines always pass. Logs carry the id, engine id,
  locality and class, never content. M1 has no per-run cloud override. Copy this pattern at every new engine call
  site (M4 language models, M6 structure models).
- **The pipeline never downloads.** If `speech.assetStatus()` is not `.ready`, or `prepare`/`transcribe` throws
  `SpeechEngineError.modelNotDownloaded`, the row fails with `FileTranscriptionPipeline.modelMissingMessage`
  ("Download the Parakeet speech model in Settings → Speech model"). A diarizer that is not ready is skipped and
  logged; a diarization error is logged and the job still completes without speakers (upstream: non-fatal).
- **Diarization runs inside the same scheduler job as transcription.** Upstream diarizes after releasing its STT
  slot; here both models run in one background slot, so two files never hold Parakeet and the diarizer in memory at
  once on the phone. Dictation (the interactive slot) is unaffected.
- **Terminal writes run outside the job's cancellation.** GRDB's async accessors throw `CancellationError` inside a
  cancelled task, so the `.cancelled`/`.failed` status and the final save go through an unstructured `Task`. The
  fake store in the tests throws the same way; keep that when changing persistence here.
- **Every write that can race a job is field-level.** Rename and favorite (Library, Transcript) use the store's
  `updateTitleOverride` / `updateFavorite`; failure and cancel marking use `transitionStatus(from: [.processing])`;
  retry uses `transitionStatus(from: [.failed, .cancelled, .interrupted], to: .processing)`. Each is one store
  transaction on the current row, so a star can never revert a just-completed transcript to `processing`, and a
  failure mark never erases a rename. Never fetch → change → `update` a row here; the tests' `FakeStore` counts
  whole-row updates and the race tests assert zero.
- **A row deleted during a job stays deleted.** `savePreservingUserMetadata` returns nil for a missing row and
  never inserts; the pipeline then logs, deletes its temp WAV and removes the media folder only if it is empty.
- **`process(id:)` runs only for a `.processing` row** (a fresh import, or one `retry` moved back); any other row is
  returned unchanged, so a finished transcript is never re-run by accident.
- **At most two jobs prepare audio at once** (`maxConcurrentAudioPreparations`). A job takes a permit before it
  normalizes and gives it back when its WAV is deleted, right after the scheduler job. So one file is normalized
  while another is transcribed, but a batch of imports (M1.5 share sheet, Voice Memos) never decodes all at once
  or fills the disk with WAVs (about 230 MB per hour of audio each). A job past the limit reports `.queued` and waits
  first come, first served; cancelling it while it waits marks it `.cancelled` without normalizing. The permit is
  pipeline state, not a scheduler slot: normalizing inside the `.fileTranscription` slot would hold the one
  background slot through a long decode and delay M2/M3 meeting work queued for it.
- **Blocking work stays off the pipeline actor and Swift's cooperative pool.** The import copy runs on the
  pipeline's file queue (`runOnFileQueue`); `AVAudioNormalizer` decodes on its own queue (see
  `ChirpAudio/README.md`). Never call a blocking file or decode API directly in an `async` function here.
- **`normalized-16k.wav` is removed on every exit** (when the permit is returned, and again by a `defer` in
  `process`); the source is never touched. The media layout is a contract:
  `spec/contracts/media-storage-layout-v1.md`.
- **One run per id.** A second `process` or `retry` for an id that is already running returns nil, so two runs
  never share and delete one WAV.
- **Progress:** importing 0.02 (reported only after the row is inserted, so a failed import leaves no entry) →
  queued 0.02 (only when the job has to wait for an audio-preparation permit) →
  normalizing 0.05–0.15 → waitingForEngine (queue and model load) → transcribing
  0.15–0.85 → identifyingSpeakers 0.85–0.95 → finishing 1.0, never decreasing. `onProgress` is called from the
  pipeline actor and from engine callbacks. `TranscriptionJobCenter.update` ignores ids that already finished,
  so a late main-actor hop cannot bring a finished job's progress back.
- **Orphaned temp audio.** A process killed mid-job leaves `normalized-16k.wav` behind. The app calls
  `sweepOrphanedTemporaryAudio()` at launch; it skips ids running in this process, folders whose name is not a UUID,
  and every source file.
- **Observed lists converge; they are not instant.** `LibraryViewModel.delete` removes the row from `items` right
  away, but a snapshot queued in `observeAll()` before the delete can briefly re-add it until the next snapshot.
- **Settings are read once per job.** A clean-up or speaker-label change applies to the next job. A
  `parakeetVariant` change is only saved here; the app must rebuild its engines (`FluidAudioEngines.makeDefault`)
  and the pipeline for it to take effect.
- **Logs:** ids, stages and error type names are `.public`. Error descriptions can name the user's files, so they
  are `.private` (spec/03 forbids logging file names and transcript text).
- **M1 imports are `.file`.** `importFile` keeps its `sourceType` parameter. Detecting video by UTType, for the
  Library's "Video" chip, is later work.

## How to verify

```bash
scripts/check.sh ChirpFeaturesTests
```

This runs the package build, the ChirpFeatures tests (pipeline, job center, Library/Capture, Transcript, Speech
settings, `UserDefaultsSettingsStore`, and the store races: `FakeStore.holdNext(_:)` parks a store call at its entry
so a test can land another writer exactly there) and the strict lint. The tests use fakes for every protocol and suspend
the fake engine with explicit signals, never sleeps. After touching cancellation, progress or observation, run
them repeatedly:

```bash
for i in $(seq 1 10); do swift test --package-path ChirpKit --filter ChirpFeaturesTests || break; done
```

Pipeline changes also need `scripts/device_smoke.sh` on the phone before they count as done (AGENTS.md §5).
