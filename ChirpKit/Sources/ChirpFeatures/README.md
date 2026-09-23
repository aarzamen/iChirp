# ChirpFeatures

The file-transcription pipeline coordinator, the deliverable generation service (M4), and the
`@MainActor @Observable` view models the app screens use.
Depends only on ChirpCore, ChirpText and ChirpExport: engines, the store and the normalizer arrive as ChirpCore
protocols, so nothing here imports FluidAudio, GRDB or AVFoundation, and every test runs on the Mac with fakes.

## Entry point

`FileTranscriptionPipeline.swift`, a port of the local-file path of upstream
`Services/TranscriptionService.swift` (`transcribe(fileURL:)` → `transcribeAudio` → `completeTranscription`). Read it
with the M1 data flow in `spec/03-architecture.md`. Then read `TranscriptionJobCenter.swift`, which owns the
pipeline's `Task`s and publishes its progress to the UI.

## What's here

- `FileTranscriptionPipeline.swift`: the `FileTranscriptionPipeline` actor plus `PipelineStage` and `JobProgress`.
  M5 adds the stages `downloading` (a link's media) and `readingDocument`, and `JobProgress.overallFraction`: a
  download fills only the first `downloadShare` (0.15) of a link job's system progress, so it never goes backwards
  when transcription starts.
  - `importFile(from:sourceType:audioTrackOrdinal:)` copies the file (security-scoped, never moved) into
    `media/<id>/source.<ext>` on the pipeline's file queue, then inserts a `.processing` row carrying the person's
    audio-track choice (nil: automatic). `process` decodes that track on every run, Retry included.
  - `audioTracks(in:)` lists a file's audio tracks (security-scoped, through the injected `trackProbe`; empty
    without one) so a multi-track file can ask before import; `canInspectAudioTracks` says whether a probe exists.
  - `process(id:)` runs: privacy routing check → model check → audio-preparation permit (at most two jobs) →
    normalize to
    `media/<id>/normalized-16k.wav` → one scheduler
    `.fileTranscription` job (`prepare`, `transcribe`, then `diarize` if enabled and ready) → `SpeakerMerger` →
    `TextRefinement` → `TitleDeriver` / `SnippetDeriver` → `FileTranscriptSegments` → `savePreservingUserMetadata`.
  - `retry(id:)` moves a `.failed` / `.cancelled` / `.interrupted` row back to `.processing` and runs `process`
    again from the stored source.
  - `sweepOrphanedTemporaryAudio()` deletes `normalized-16k.wav` files left by a killed process (call at launch).
- `TranscriptionJobCenter.swift`: the running jobs. `start(filesAt:pipeline:)` (and the one-file
  `start(fileAt:pipeline:)`) does import and process per file in one tracked `Task` each, and `retry` and `cancel`
  act by transcription id. `progress[id]` feeds "Transcribing · NN%", and `lastImportError` is set when a file could
  not even be imported (`dismissImportError()` clears it). `progressHandler` is the pipeline's `onProgress`.
  `onImportSettled` is called once per incoming file after its import attempt ends (imported or not); the app uses
  it to delete iOS's temporary Inbox copy. Given a `ContinuedProcessingScheduling` at init, each `start(filesAt:)`
  and each `retry` (a person's action) also submits one background request; its expiration cancels that action's
  jobs. With a track probe, `start(filesAt:)` first lists every file's audio tracks; a batch with a multi-track file
  waits in `pendingAudioTrackSelection` (`AudioTrackSelectionRequest`) until `selectAudioTrack(_:for:)` starts it
  (the choice for multi-track files, automatic for the rest) or `cancelAudioTrackSelection(_:)` drops it (its files
  count as settled). Later batches queue behind it. Contract: `spec/contracts/file-transcription-audio-tracks-v1.md`.
  M5 (additive): `start(filesAt:importer:)` and `retry(_:title:importer:)` run any `ItemImporting` (documents) the
  same way, and `startTracked(_:title:work:)` tracks work for an existing row (a link's download, then its
  transcription) with its own background request, cancellable by `cancel(id)`.
- `DocumentImportPipeline.swift` (M5): documents, an `ItemImporting` the job center runs. `importItem(from:)` copies
  the file into `media/<id>/source.<ext>` and inserts a `.processing` `.document` row with its `documentFormat`
  (nothing left behind on failure; unsupported types throw); `process(id:)` extracts on device through
  `DocumentTextExtracting` with `.readingDocument` page progress, derives title and snippet, and saves with
  `savePreservingUserMetadata`; `retry(id:)` re-extracts from the kept source. No engine, no scheduler slot, no network.
- `LinkImportViewModel.swift` (M5): the Paste a link sheet. `text` is classified locally on every change (`kind`);
  `transcribe()` is the one networked action: podcast and media links get their row and continue as a tracked job
  (`startMediaJob`, wired by the app to `startTracked`), YouTube links finish in the sheet; errors stay in the sheet
  (`phase == .failed`) with no row created. `reset()` clears it for another link.
- `IncomingFileInbox.swift` also answers `kind(of:)` (M5): documents (and any other plain text) versus media, for
  routing a shared file.
- `LinkIngestService.swift` (M5): links. `resolve(_:)` turns a `LinkKind` into a `ResolvedLink` on the person's tap
  (podcast lookup, feed read or content-type probe; nothing is created), `createRow(for:)` inserts the `.processing`
  row with `sourceURL` / `sourceTitle`, `download(id:from:)` fetches into `media/<id>/source.<ext>` with
  `.downloading` progress and records the file (failure → `failed` with a message, cancel → `cancelled`, partial file
  kept), and `retryDownload(id:)` resumes it. `importCaptions(videoID:link:)` (Step 3) stores a YouTube video's captions as a
  `.completed` `.url` row (words timed across each caption, segments, `engine` `youtube.captions`, no audio); no row
  on failure. `needsDownload(_:)` tells Retry which path a link row takes; the file
  pipeline then runs unchanged. Downloads never hold a speech-scheduler slot.
- `BackgroundContinuation.swift` (M1.5): the bridge between a user action's work and the system's continued-processing
  task. `ContinuedProcessingScheduling` (submit / withdraw) and `ContinuedProcessingTask` (progress, expiration,
  title, completion) are the two protocols the app implements over `BackgroundTasks`
  (`App/Sources/Support/ContinuedProcessing.swift`); tests use fakes. `BackgroundContinuation` keeps one request per
  user action: `update(_:fraction:stage:)` feeds the mean of its items' real fractions to the task (never
  decreasing), `end(_:succeeded:)` completes the task when every item ended (success only if all succeeded) or
  withdraws a request the system never started, and expiration calls `onExpiration` (the owner cancels the work)
  and completes once the items end or after `expirationGrace`.
- `IncomingFileInbox.swift`: the app's `Documents/Inbox/`, where iOS copies a file another app hands to Parakeet
  (Share sheet → Parakeet, Files → Open in; M1.5). `contains(_:)` and `removeIfInside(_:)` only ever touch files
  strictly inside that folder, never a file the user picked with the document picker.
- `LibraryViewModel.swift`: all rows from `observeAll()`, filter chips, search, "Today" / "Yesterday" / "MMM d"
  sections, delete (row plus its `media/<id>/` folder and any `ExportTempFiles` export folder for it), favorite, and
  `loadError` / `dismissLoadError()`.
- `TranscriptViewModel.swift`: one row. Paragraphs come from `TranscriptParagraphBuilder`; without words there is one
  `displayText` paragraph. Also speaker labels, `mediaURL` for the player, `plainText` for Copy, `exportFile` into
  `<tmp>/export-<id>/`, rename and favorite.
- `SpeechSettingsViewModel.swift`: the speech and diarizer model status, download with progress (an optional
  `onProgress` also receives each fraction, for the system's progress UI; both downloads return whether the model is
  ready), delete (the engine's "in use" refusal lands in `lastError`, cleared by `dismissError()`), and
  `settingsValue`, which saves on every set — only the fields Settings edits, onto the freshest stored value, so the
  dictation screen's "Polish after" (M2) is never overwritten by an older copy.
- `CaptureViewModel.swift`: the three newest rows for Capture's "Recent".
- `Dictation/DictationFlowStateMachine.swift` (M2): port of upstream's pure dictation flow (events in → state and
  effects out, a generation that rejects stale completions): `idle → starting → recording ⇄ paused → stopping →
  done | failed | cancelled`, stop-while-starting as `pendingStop`, a start during the final pass shows "busy" and
  cancels nothing, Retry from `failed`.
- `Dictation/DictationCoordinator.swift` (M2): the `@MainActor @Observable` dictation coordinator and view model.
  Start checks the model and the microphone permission, records into `media/<id>/dictation.wav` through
  `ChirpCore.AudioCapturing`, warms the model, and shows display-only live text from a `LiveSpeechSession` through
  `LiveTranscriptStabilizer` (`committedText` / `tentativeText`), plus real levels and recorded seconds. Stop finishes
  the recording, **finishes (cancels and drains) the live session**, inserts a `.processing` `dictation` row, runs
  the final pass (`scheduler.run(.dictation)`, purpose `.dictation`), refines with `TextRefinement` (Clean when
  "Polish after" is on, else the saved clean-up mode; custom words and snippets from `textRules`), saves, and copies
  the text through `ClipboardWriting`. Failure: row `.failed`, audio kept, Retry; no speech: "Didn’t catch that";
  under 0.3 s: nothing kept. Cancel is the discard (no row, no folder). `retry(transcriptionID:)` serves the Library
  (no copy); `recoverOrphanedRecordings()` adopts a `dictation.wav` without a row as `.interrupted` at launch.
- `TextRulesViewModel.swift` (M2): Settings → Text → Custom words & snippets over `ChirpText.TextRulesStoring`:
  add (trimmed; a blank replacement is none), edit, on/off, delete, readable errors for empty fields and duplicates;
  `DictationTextRules.enabled(in:)` reads the enabled lists for a dictation.
- `SettingsStore.swift`: `SettingsStoring` and `UserDefaultsSettingsStore`, a JSON blob under
  `ichirp.transcriptionSettings` that falls back to the defaults when missing or unreadable.
- `LanguageModelProviderStore.swift`: `LanguageModelProviderStoring` and `UserDefaultsLanguageModelProviderStore`
  (Settings → Models): provider metadata as a JSON blob under `ichirp.languageModelProviders`, each API key in the
  injected `SecretStoring` (the Keychain) under the provider's `secretAccount`, never in `UserDefaults`. The key is
  written before the metadata; `routingPolicy()` trusts exactly the LAN hosts the user marked trusted.
- `DeliverableService.swift`: **the only path from a transcript to a `LanguageModel`** (M4; contract
  `spec/contracts/deliverables-v1.md`). `route(transcriptionID:templateID:model:)` answers `.allowed` or
  `.needsOverride(PrivacyOverrideRequest)` without sending anything; `confirmOverride(_:)` mints a single-use
  `PrivacyOverride` bound to that transcript, engine, host, locality and class (10-minute lifetime);
  `generate(templateID:transcriptionID:userNotes:model:override:)` and `ask(question:…)` stream
  `DeliverableRunEvent`s; `setPrivacyClass(_:transcriptionID:)` sets a transcript's class and raises (never lowers)
  its deliverables; `installBuiltInTemplates()` installs `BuiltInTemplates.all`.
- `MapReduceGenerator.swift`: `DeliverablePromptAssembler` (tagged source blocks, `{{transcript}}` /
  `{{userNotes}}` placement, Ask citation rules), `GenerationBudget` (from the engine's context window: a quarter
  reserved for output, 3 characters per token, 10% margin) and `MapReduceGenerator` (one call when it fits;
  otherwise extract per part, condense in groups up to 4 levels, combine; never truncates, else
  `transcriptTooLong`).
- `BuiltInTemplates.swift`: the nine shipped templates (Summary, Meeting notes, Action items, Agenda, SOAP note with
  a clinical output class, Polish, Distill, Decide, Brief). Ids and canonical keys are reserved forever.
- `DeliverableRunViewModel.swift`: one Transform or Ask run for a screen: `start()` routes, `.needsConfirmation`
  waits for `confirmOverride()` / `declineOverride()`, then streams into `text` and ends in `.completed`,
  `.answered` or `.failed(sentence)`.
- `LanguageModelsViewModel.swift` (M4 UI): Settings → Models and the model a run uses.
  - `LanguageModelFactory` is the protocol the app implements over `ChirpEngineAppleFM` and `ChirpEngineHTTPLLM`
    (`App/Sources/LanguageModels/AppLanguageModelFactory.swift`); tests use a fake.
  - `LanguageModelChoice` is Apple's on-device model or one provider; `ModelPlace` words where it runs ("on this
    iPhone", "on Mac Studio", "in the cloud (Claude)").
  - `LanguageModelProviderDraft` is the provider form: locality derived from the typed address, the trust switch only
    for a home-network host, `apiKeyChange` (a blank key keeps the stored one), and `problem` as a sentence.
  - `LanguageModelsViewModel` lists providers and Apple's availability, sets the default, saves and deletes through
    the provider store (key to the Keychain first), tests a connection and lists models (typed key, else the stored
    one), and builds a run's engine with `makeModel(for:)`, reading the key just then.
- `DeliverableLibraryViewModel.swift` (M4 UI): `DeliverableLibraryViewModel` (the Transforms tab: templates by
  category and recent documents) and `DeliverableDocumentViewModel` (one document: text, template version number,
  `save()` through `updateDeliverableText`, `delete()`); neither ever writes a transcript.
- `AskSessionViewModel.swift` (M4 UI): the Ask tab's questions, one `DeliverableRunViewModel(.ask)` each, one at a
  time; answers are not stored (the ledger records each run without content).

## Meetings (M3, `Meeting/`)

Contract: `spec/contracts/meeting-session-v1.md`. Plan: `docs/plans/2026-09-22-012-m3-meetings.md`.

- `MeetingCoordinator.swift`: the Meeting screen's `@MainActor @Observable` model (`MeetingFlowState`: idle,
  starting, recording, paused, interrupted, waitingForResume, stopping, saved, failed). Start writes
  `recording.lock` **before** the recorder starts; Stop closes the audio, moves the lock to
  `awaitingTranscription`, inserts the `.processing` meeting row with the notes, and runs the finalizer. Pause and
  mute go to the recorder; interruptions arrive as capture events. Notes are written into the lock about a second
  after typing stops and at Stop. The only deletes: `discard()` (the screen confirms first), a start that failed
  before any audio, and a recording under 0.3 s (the dictation rule). Low storage refuses to start under 200 MB and
  warns under 1 GB.
- `MeetingSessionLockStore.swift`: atomic `recording.lock` writes, reads (malformed notes lose only the notes; a
  newer schema is opaque), `hasLockFile` (the retention barrier) and `discoverOrphans()` (locks from another app
  launch; one store per launch, whose `launchId` it stamps).
- `MeetingLiveChunking.swift`: `SpeechBoundaryMeetingLiveAudioChunker` (upstream VAD chunker: 2–10 s cuts on speech
  end, 0.25 s overlap after a forced cut, silence windows dropped, fixed fallback after 3 VAD errors) and
  `FixedMeetingLiveAudioChunker` (5 s / 1 s overlap) when the VAD model is not on disk.
- `MeetingLiveTranscriber.swift`: each chunk (RMS above 0.00025) is written to `chunks/` and transcribed with
  `SpeechEngine.transcribe(fileAt:)` inside `.meetingLiveChunk`; outcomes apply in order into
  `MeetingTranscriptAssembler.swift` (words offset by the chunk start, de-duplicated by absolute `endMs`).
  Display-only; a backpressure drop marks the preview lagging. `finish()` cancels and awaits every chunk.
- `MeetingFinalizer.swift`: normalize `meeting.caf` → one `.meetingFinalize` job (transcribe, then diarize; a
  diarization failure is not fatal) → `SpeakerMerger` → custom words only → title, snippet, segments →
  `savePreservingUserMetadata` → delete the lock only for a completed meeting row (settlement). Failures keep the
  row (`.failed`, Retry), the lock and the audio. Privacy routing is checked before any audio is prepared and again
  inside the slot. Diarization shares the background slot with the final pass, so dictation's interactive slot is
  never blocked; its cost is part of the finalize time.
- `MeetingRecoveryService.swift`: `discoverPendingRecoveries()` (orphans whose row is missing, processing or
  interrupted; a completed row only settles its leftover lock; failed rows are the Library's Retry), `recover`
  (claims the lock for this launch, removes `chunks/`, inserts or reuses the row with the lock's notes and
  `isPartialAudio` when the kill cut the recording, then finalizes) and `discard` (row and folder; after the
  person confirms).
- `MeetingAudioRetention.swift`: `MeetingAudioRetentionPolicy` (completed meetings with audio, no lock file, older
  than N days; keep forever by default) and `MeetingAudioRetentionSweeper` (marks the row `audioRemovedAt` first,
  then deletes `meeting.caf`; the transcript and notes stay).
- `TranscriptNotesViewModel.swift`: the Transcript's Notes tab (notes saved with `updateUserNotes`, blank clears;
  speaker rename with `renameSpeaker`, blank names refused).
- `MeetingSettingsViewModel.swift`: Settings → Meetings (retention choice saved onto the freshest settings; the
  voice-activity model's status, explicit download and delete).

## Structure models (M6, `Structure/`; plan 015, contract [structure-model-plugin-v1](../../../spec/contracts/structure-model-plugin-v1.md))

- `Structure/StructureCatalog.swift`: `JSONValue`, `StructureTool`, `StructureCatalog` (frozen, versioned catalogs
  loaded from `Resources/StructureCatalogs/`: `soap-meds.v1`, `dictation-commands.v1`; `toolsJSON` is what a model
  reads, without the spoken `phrases`), `StructuredCall` (parse a call array; `problems(against:)` names unknown
  tools, missing required arguments and values outside an enum). A test pins each catalog file's SHA-256: a change
  ships as a new version file.
- `Structure/StubStructureModel.swift`: the rule-based **STUB** engine (`stub.rules`) for both catalogs, with a
  pseudo-confidence; always available and always labelled STUB. `VoiceCommandText` (a command is a whole short
  utterance that equals one of its phrases, optionally after "okay"/"please").

## Wiring (app composition root)

```swift
let jobs = TranscriptionJobCenter(continuedProcessing: SystemContinuedProcessingScheduler())  // nil in tests
let pipeline = FileTranscriptionPipeline(
    paths: paths, store: store, normalizer: normalizer, trackProbe: normalizer,   // AVAudioNormalizer is both
    speech: engines.speech, diarizer: engines.diarizer,
    scheduler: scheduler, settings: settings, onProgress: jobs.progressHandler)
_ = try await store.markStaleProcessingAsInterrupted()     // at launch, then:
await pipeline.sweepOrphanedTemporaryAudio()
jobs.onImportSettled = { url in inbox?.removeIfInside(url) } // inbox = IncomingFileInbox.appDefault()
jobs.start(filesAt: pickedOrSharedURLs, pipeline: pipeline) // per user action
LibraryViewModel(store: store, paths: paths)               // paths: delete removes media/<id>/ too
let dictation = DictationCoordinator(                      // M2
    capture: DictationRecorder(stream: microphone, session: audioSession),
    speech: engines.speech, liveSessions: engines.speech, scheduler: scheduler, store: store, paths: paths,
    settings: settings, clipboard: SystemClipboard(), textRules: { /* custom words + snippets */ })
await dictation.recoverOrphanedRecordings()                // at launch, after the interrupted sweep
let lockStore = MeetingSessionLockStore(paths: paths)      // M3: one per launch
let finalizer = MeetingFinalizer(paths: paths, store: store, normalizer: normalizer, speech: engines.speech,
    diarizer: engines.diarizer, scheduler: scheduler, settings: settings, lockStore: lockStore,
    customWords: { /* enabled custom words */ }, onProgress: jobs.progressHandler)
let meeting = MeetingCoordinator(recorder: MeetingRecorder(stream: microphone, session: audioSession),
    speech: engines.speech, voiceActivity: FluidAudioEngines.makeVoiceActivity(), scheduler: scheduler,
    store: store, paths: paths, lockStore: lockStore, finalizer: finalizer)
let recovery = MeetingRecoveryService(paths: paths, store: store, lockStore: lockStore, finalizer: finalizer,
    normalizer: normalizer)
await MeetingAudioRetentionSweeper(paths: paths, store: store, lockStore: lockStore, settings: settings).sweep()
let pending = await recovery.discoverPendingRecoveries()   // at launch: the recovery sheet
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
- **The background task never drives the job** (M1.5). Jobs start at once; `BackgroundContinuation` only mirrors
  their real progress to the system and cancels them on expiration. A refused request (the Simulator, or the system
  under load) changes nothing about the job. Every ending stays one of `completed`, `failed`, `cancelled` or, after a
  kill, `interrupted` (spec/05 "M1.5: continued processing").
- **A track choice is made before anything exists** (M1.5). Two or more audio tracks: no row, no copy, no work and
  no background request until the person picks; the request is submitted by that tap. A file whose tracks cannot be
  read never asks: it imports as in M1 and its row reports the real error. A stored ordinal the file lacks fails the
  row (`AudioTrackSelectionError.trackMissing`); nothing falls back to another track.
- **Settings are read once per job.** A clean-up or speaker-label change applies to the next job. A
  `parakeetVariant` change is only saved here; the app must rebuild its engines (`FluidAudioEngines.makeDefault`)
  and the pipeline for it to take effect.
- **Logs:** ids, stages and error type names are `.public`. Error descriptions can name the user's files, so they
  are `.private` (spec/03 forbids logging file names and transcript text).
- **M1 imports are `.file`.** `importFile` keeps its `sourceType` parameter. Detecting video by UTType, for the
  Library's "Video" chip, is later work.

## Deliverables and privacy routing (M4)

- **Every model call goes through `DeliverableService`.** `SingleGenerationPathTests` fails when any other file in
  ChirpFeatures or `App/Sources` calls `LanguageModel.generate`. Screens call the service or
  `DeliverableRunViewModel`, never an engine.
- **Routing happens before the first call and again before every later call**, against the class stored at that
  moment and the policy as configured then (the provider store's `routingPolicy()`). The routing class is the
  stricter of the transcript's class and the template's output class, so a SOAP run is clinical.
- **Clinical content to a cloud or untrusted LAN engine needs a `PrivacyOverride`**: only `confirmOverride` makes
  one, only from a request this service issued, for one run. The UI must call it only from the user's tap on
  "Send" in the confirmation that shows `request.title` and `request.message`; never from code that did not ask.
  In the app that is `ClinicalConfirmationActions.userTappedSend()`
  (`App/Sources/Screens/Transforms/ClinicalConfirmation.swift`), and `AppTests/ClinicalConfirmationTests` fails when
  any other app code calls `confirmOverride`.
  Its use is logged as `privacy_override_used` (ids, engine id, locality; host `.private`) and recorded as
  `llm_runs.privacyOverride`. A LAN engine that does not report `endpointHost` is never trusted.
- **Every run that reaches routing writes one `llm_runs` row** (succeeded, failed, cancelled or refused), outside
  the run's cancellation, with no content. Logs carry ids, engine ids, classes, counts and error kind names only.
- **Nothing is truncated.** Input over budget is split; a `contextTooLong` from a model re-plans with half the
  window (twice at most); input that still cannot fit fails with `transcriptTooLong` and stores nothing.
- **Results are new rows.** The transcript is never written except by `setPrivacyClass`.

## How to verify

```bash
scripts/check.sh ChirpFeaturesTests
```

The M4 tests on their own: `swift test --package-path ChirpKit --filter
"DeliverableService|MapReduceGenerator|DeliverableRunViewModel|SingleGenerationPath|BuiltInTemplates|LanguageModelProviderStore"`.
`DeliverableServiceRoutingTests.testFullPrivacyMatrix` prints the 24-row routing matrix it checked.

This runs the package build, the ChirpFeatures tests (pipeline, job center, Library/Capture, Transcript, Speech
settings, dictation coordinator and flow state machine, `UserDefaultsSettingsStore`, and the store races: `FakeStore.holdNext(_:)` parks a store call at its entry
so a test can land another writer exactly there) and the strict lint. The tests use fakes for every protocol and suspend
the fake engine with explicit signals, never sleeps. After touching cancellation, progress or observation, run
them repeatedly:

```bash
for i in $(seq 1 10); do swift test --package-path ChirpKit --filter ChirpFeaturesTests || break; done
```

Pipeline changes also need `scripts/device_smoke.sh` on the phone before they count as done (AGENTS.md §5).
