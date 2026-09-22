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
  - `importFile(from:sourceType:)` copies the file (security-scoped, never moved) into `media/<id>/source.<ext>` and
    inserts a `.processing` row.
  - `process(id:)` runs: model check → normalize to `media/<id>/normalized-16k.wav` → one scheduler
    `.fileTranscription` job (`prepare`, `transcribe`, then `diarize` if enabled and ready) → `SpeakerMerger` →
    `TextRefinement` → `TitleDeriver` / `SnippetDeriver` → `FileTranscriptSegments` → `savePreservingUserMetadata`.
  - `retry(id:)` resets the row to `.processing` and runs `process` again from the stored source.
- `TranscriptionJobCenter.swift`: the running jobs. `start(fileAt:pipeline:)` does import and process in one tracked
  `Task`, and `retry` and `cancel` act by transcription id. `progress[id]` feeds "Transcribing · NN%", and
  `lastImportError` is set when a file could not even be imported. `progressHandler` is the pipeline's `onProgress`.
- `LibraryViewModel.swift`: all rows from `observeAll()`, filter chips, search, "Today" / "Yesterday" / "MMM d"
  sections, delete (row plus its `media/<id>/` folder) and favorite.
- `TranscriptViewModel.swift`: one row. Paragraphs come from `TranscriptParagraphBuilder`; without words there is one
  `displayText` paragraph. Also speaker labels, `mediaURL` for the player, `plainText` for Copy, `exportFile` into
  `<tmp>/export-<id>/`, rename and favorite.
- `SpeechSettingsViewModel.swift`: the speech and diarizer model status, download with progress, delete (the
  engine's "in use" refusal lands in `lastError`), and `settingsValue`, which saves on every set.
- `CaptureViewModel.swift`: the three newest rows for Capture's "Recent".
- `SettingsStore.swift`: `SettingsStoring` and `UserDefaultsSettingsStore`, a JSON blob under
  `ichirp.transcriptionSettings` that falls back to the defaults when missing or unreadable.

## Wiring (app composition root)

```swift
let jobs = TranscriptionJobCenter()
let pipeline = FileTranscriptionPipeline(
    paths: paths, store: store, normalizer: normalizer, speech: engines.speech, diarizer: engines.diarizer,
    scheduler: scheduler, settings: settings, onProgress: jobs.progressHandler)
jobs.start(fileAt: pickedURL, pipeline: pipeline)          // per imported file
LibraryViewModel(store: store, paths: paths)               // paths: delete removes media/<id>/ too
```

## What to know before editing

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
- **A row deleted during a job stays deleted.** The final save first checks the row still exists
  (`savePreservingUserMetadata` would insert it again). Failure and cancel marking use `update`, which refuses a
  missing row.
- **`normalized-16k.wav` is removed on every exit** (a `defer` in `process`); the source is never touched. The
  media layout is a contract: `spec/contracts/media-storage-layout-v1.md`.
- **One run per id.** A second `process` or `retry` for an id that is already running returns nil, so two runs
  never share and delete one WAV.
- **Progress:** importing 0.02 → normalizing 0.05–0.15 → waitingForEngine (queue and model load) → transcribing
  0.15–0.85 → identifyingSpeakers 0.85–0.95 → finishing 1.0, never decreasing. `onProgress` is called from the
  pipeline actor and from engine callbacks. `TranscriptionJobCenter.update` ignores ids that already finished,
  so a late main-actor hop cannot bring a finished job's progress back.
- **User metadata writes are fetch-then-update.** `TranscriptionStoring` has no field-level update, so rename and
  favorite (Library, Transcript) and the pipeline's failure marking read the freshest row and write it back whole.
  A write that lands between that read and write is overwritten. The window is two back-to-back store calls; a
  store method such as `updateUserMetadata(id:titleOverride:isFavorite:)` would close it.
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
settings, `UserDefaultsSettingsStore`) and the strict lint. The tests use fakes for every protocol and suspend
the fake engine with explicit signals, never sleeps. After touching cancellation, progress or observation, run
them repeatedly:

```bash
for i in $(seq 1 10); do swift test --package-path ChirpKit --filter ChirpFeaturesTests || break; done
```

Pipeline changes also need `scripts/device_smoke.sh` on the phone before they count as done (AGENTS.md §5).
