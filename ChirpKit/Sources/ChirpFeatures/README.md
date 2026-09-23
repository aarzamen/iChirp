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
  when transcription starts. Plan 019 adds `JobProgress.isIndeterminate` (`.indeterminate(stage)`,
  `determinateFraction`): a download whose size is unknown shows "Downloading…" and a spinner, never "0%".
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
  (`phase == .failed`) with no row created. `reset()` clears it for another link. Plan 019: when captions are missing
  (or YouTube refuses them) and a Mac companion is set up, `phase == .companionOffer(reason)`; the person confirms
  once per link (`needsCompanionConfirmation`, `confirmCompanion()`) and `getAudioFromMac()` starts a `.companion`
  job. Without a companion the failure keeps the captions error's own advice (try again later, share the file) and
  adds how to set one up.
- `CompanionSettingsStore.swift` (plan 019): Settings → Mac companion. Host, port and the trusted flag in
  `UserDefaults` (`ichirp.companion`); the pairing token only in `SecretStoring` (`companion.pairing-token`). It is
  **the concrete `CompanionConfiguration`** (ChirpCore) that plan 020's voices read, makes the `CompanionClient`
  (`makeClient()`), and adds a trusted home-network companion to a routing policy (`routingPolicy(adding:)`); M4's
  language-model routing is unchanged. `CompanionAddress.parse` reads "host", "host:port" or a pasted
  `http://host:port/…`, and refuses an address that is not on the home network (`notHomeNetwork`).
- `CompanionSettingsViewModel.swift` (plan 019): the Mac companion form. The token field is write-only (empty keeps the
  saved token); an internet address can be neither saved nor tested; Test connection checks health without the token
  and the voices list with it (`testState`), sending the saved token only to the saved address.
- `IncomingFileInbox.swift` also answers `kind(of:)` (M5): documents (and any other plain text) versus media, for
  routing a shared file.
- `LinkIngestService.swift` (M5): links. `resolve(_:)` turns a `LinkKind` into a `ResolvedLink` on the person's tap
  (podcast lookup, feed read or content-type probe; nothing is created), `createRow(for:)` inserts the `.processing`
  row with `sourceURL` / `sourceTitle`, `download(id:from:)` fetches into `media/<id>/source.<ext>` with
  `.downloading` progress and records the file (failure → `failed` with a message, cancel → `cancelled`, partial file
  kept), and `retryDownload(id:)` resumes it. `importCaptions(videoID:link:)` (Step 3) stores a YouTube video's captions as a
  `.completed` `.url` row (words timed across each caption, segments, `engine` `youtube.captions`, no audio); no row
  on failure. `needsDownload(_:)` tells Retry which path a link row takes; the file
  pipeline then runs unchanged. Downloads never hold a speech-scheduler slot. Plan 019: `LinkMediaSource.transport`
  (`.direct` / `.companion`), `download(id:source:)` dispatches on it, and `downloadFromCompanion(id:link:)` sends only
  the canonical `https://www.youtube.com/watch?v=<id>` (rebuilt from the validated id; share parameters never leave
  the phone) to the Mac companion (`CompanionAudioFetching`, injected as a closure read at each use) and records the
  returned `source.m4a` with the video's title and duration. Retry of a YouTube row asks the companion again only
  while it is the companion the link was confirmed for in this launch (`companionRetryConfirmationHost(id:)` tells
  the app to ask first; `confirmCompanionRetry(id:)` records the answer; otherwise the row fails
  `companionNotConfirmed` and nothing is sent).
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
- `SpeechEnginesViewModel.swift` (M7, plan 016): Settings → Speech engines.
  - It lists one row per engine build from `SpeechEngineCapabilityRegistry`. Each row is either a registered instance
    with its model state, or a row this build or device cannot run, listed with the reason: not in this build, over
    the memory budget, or `SpeechEngineAvailabilityReporting`.
  - `choices(for:)` returns only ready engines (for live, also able to preview) plus the current choice.
  - `select` (async) goes through `SpeechEngineRouter.select`, which refuses during a meeting and refuses a live
    engine too big to share memory with the final one; a Transcripts choice too big for the live engine moves live
    text to it as well (`lastNotice` says so). Then `releaseUnroutedModels()` unloads the engine that left both
    routes (review I3).
  - `download` goes through the engine. `delete` (review I2) refuses an engine a route uses while a meeting holds the
    lease; otherwise each route that used it goes back to Parakeet first (Transcripts first), `lastNotice` says so,
    and then the model is deleted. `routesUsing(_:)` lets the delete dialog say it beforehand. Deleting Parakeet
    itself leaves the routes (it is the fallback).
- `SpeechModelMissing.swift` (review I2): `SpeechModelMissingError`, built from the engine a job resolved. For
  Parakeet, or when the consumer was given one engine instead of a router, it keeps
  `FileTranscriptionPipeline.modelMissingMessage`. For another routed engine it names it: "Whisper Base isn’t
  downloaded on this iPhone. Download it in Settings → Speech engines, or switch Transcripts to Parakeet".
  `mapping(_:engine:configured:)` turns an engine's own `modelNotDownloaded` into it. The file pipeline, the dictation
  (start check and final pass) and `MeetingFinalizer` all use it, so a route pointing at a deleted or never-restored
  model is never a dead end; Retry resolves the route again.
- `SpeechRouteStore.swift` (M7): `SpeechRouteStoring` and `UserDefaultsSpeechRouteStore`. The live and final routes
  are saved as JSON under `ichirp.speechRoutes`. A missing or unreadable value means Parakeet on both.
- `CaptureViewModel.swift`: the three newest rows for Capture's "Recent".
- `Dictation/DictationFlowStateMachine.swift` (M2): port of upstream's pure dictation flow (events in → state and
  effects out, a generation that rejects stale completions): `idle → starting → recording ⇄ paused → stopping →
  done | failed | cancelled`, stop-while-starting as `pendingStop`, a start during the final pass shows "busy" and
  cancels nothing, Retry from `failed`.
- `Dictation/DictationCoordinator.swift` (M2; M6 voice-command hooks): the `@MainActor @Observable` dictation
  coordinator and view model.
  Start checks the model and the microphone permission, records into `media/<id>/dictation.wav` through
  `ChirpCore.AudioCapturing`, warms the model, and shows display-only live text from a `LiveSpeechSession` through
  `LiveTranscriptStabilizer` (`committedText` / `tentativeText`), plus real levels and recorded seconds. Stop finishes
  the recording, **finishes (cancels and drains) the live session**, inserts a `.processing` `dictation` row, runs
  the final pass (`scheduler.run(.dictation)`, purpose `.dictation`), refines with `TextRefinement` (Clean when
  "Polish after" is on, else the saved clean-up mode; custom words and snippets from `textRules`), saves, and copies
  the text through `ClipboardWriting`. `failureKind` (`DictationFailureKind`: speech model missing, microphone
  denied, other) tells the Dictating screen which fix to offer, never by comparing sentences. M7: the start check
  and the final pass use the final route's engine and name it when its model is missing (`SpeechModelMissingError`).
  Failure: row `.failed`, audio kept, Retry; no speech: "Didn’t catch that";
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
  written before the metadata; `routingPolicy()` trusts exactly the LAN hosts the user marked trusted. M7 adds
  `defaultLocalModelID()` / `setDefaultLocalModelID(_:)` (the small on-device model picked as default; absent in
  older saves).
- `DeliverableService.swift`: **the only path from a transcript to a `LanguageModel`** (M4; contract
  `spec/contracts/deliverables-v1.md`). `route(transcriptionID:templateID:model:)` answers `.allowed` or
  `.needsOverride(PrivacyOverrideRequest)` without sending anything; `confirmOverride(_:)` mints a single-use
  `PrivacyOverride` bound to that transcript, engine, host, locality and class (10-minute lifetime);
  `generate(templateID:transcriptionID:userNotes:model:override:)` and `ask(question:…)` stream
  `DeliverableRunEvent`s; `setPrivacyClass(_:transcriptionID:)` sets a transcript's class and raises (never lowers)
  its deliverables; `installBuiltInTemplates()` installs `BuiltInTemplates.all`. Routes (first check and every
  later call) use the transcript's `EffectivePrivacyClass`.
- `EffectivePrivacyClass.swift`: **the one rule for how private a transcript's content is** when it may leave the
  phone: the stricter of the transcript's class and every deliverable made from it (a personal transcript with a
  clinical SOAP note is clinical; review L4 M1). `DeliverableService`, `DecisionService` and `VoicePlayer`'s class
  provider read it as stored at each check.
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
  - `LanguageModelFactory` is the protocol the app implements over `ChirpEngineAppleFM`, `ChirpEngineHTTPLLM` and
    (M7) `ChirpEngineLlamaCpp` (`App/Sources/LanguageModels/AppLanguageModelFactory.swift`,
    `App/Sources/LanguageModels/AppLocalLanguageModels.swift`); tests use a fake. Its small-model requirements
    (`localModelOptions`, `localModelRuntimeProblem`, `makeLocalModel(id:)`, `localModelAssets(id:)`,
    `localModelAvailability(id:)`) have empty defaults.
  - `LanguageModelChoice` is Apple's on-device model, a downloaded small model on this iPhone (`.localModel(id)`, on
    device, trusted for clinical items) or one provider; `ModelPlace` words where it runs ("on this iPhone", "on Mac
    Studio", "in the cloud (Claude)").
  - `LanguageModelProviderDraft` is the provider form: locality derived from the typed address, the trust switch only
    for a home-network host, `apiKeyChange` (a blank key keeps the stored one), and `problem` as a sentence.
  - `LanguageModelsViewModel` lists providers and Apple's availability, sets the default, saves and deletes through
    the provider store (key to the Keychain first), tests a connection and lists models (typed key, else the stored
    one), and builds a run's engine with `makeModel(for:)`, reading the key just then. M7: it lists the small models
    (`localModels`, `localModelStatus`), offers one for runs only once its file is `.ready`, downloads (only on a
    Settings tap) and deletes it (a deleted default falls back to Apple's model), and keeps one default at a time.
    Review I3d: `refresh()` also reads each small model's `localModelAvailability` (no network, nothing loaded);
    `unavailableReason(for:)` gives the sentence the Transform and Ask sheets show before Start (Apple's model and
    small models: not downloaded, would not fit in memory), and `unavailableLocalModels` lists the ones the pickers
    show disabled, with why.
- `LocalLanguageModels.swift` (M7, ADR-015): `LocalModelOption` (catalog id, name, tier, runtime, license, source,
  download size, memory while loaded, window, `isMeasuredOnIPhone`), the `LanguageModelFactory` defaults and
  `LanguageModelChoice(localModel:)`. Review I3: `LocalModelFit` (memory need against `os_proc_available_memory`),
  `downloadNotice(availableMemoryBytes:)` (the question before any download over 1 GB, an unmeasured model, or one
  that would not fit: size, memory, "Download Anyway"), `measurementCaution` ("Not yet measured on iPhone", louder for
  the quality tier) and `UnavailableLocalModel`. Tests: `LocalModelFitTests`.
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

## Voice output (plan 020, `Voice/`)

- `Voice/VoicePlayer.swift`: the `@MainActor @Observable` reader behind Listen, spoken Ask answers and plan 015's
  dictation "read back" (`speak(text:privacyClass:source:)`), ported from Readback's `SynthQueue`. States `idle`,
  `preparing`, `needsConfirmation`, `speaking(chunk, of)`, `paused`, `failed` (with `retry()` from the failed
  chunk). One synthesis at a time, exactly one chunk ahead of the one playing; transient errors retried twice.
  **Routing:** `availability()` first (sends no text), then `PrivacyRoutingPolicy` before the first chunk, every
  later chunk and every retry, with the class **as stored at that moment**: the injected `currentPrivacyClass`
  provider (the app passes `VoiceSourcePrivacy.current(for:…)`, the `EffectivePrivacyClass` rule) raises, never
  lowers, the class the reading started with. Clinical text to a cloud voice or an untrusted Mac waits in
  `.needsConfirmation` (`VoiceConfirmationRequest`, "Read this clinical text aloud with Grok voices?") until
  `confirmPendingSpeech(requestID:)` (the dialog's Read aloud button only, for the question it showed) or
  `declinePendingSpeech()`; when the class rises (or the Mac loses its trust) mid-reading, the audio stops before the
  next chunk is sent and the question is asked, and Read aloud resumes at the chunk that was playing. The confirmation
  covers that utterance's engine, locality, host and class only. `canRetry` is false for a failure with nothing to
  retry. `VoiceSource` names what is read (an Ask answer carries its transcript's id; logs carry its kind, engine id,
  class and counts, never text). `VoiceSourcePrivacy` maps a source to its stored class (`.clinical` when the store
  cannot be read). `VoicePlayer.routingPolicy(companion:)` is the voices' policy: only the companion's own trust
  counts, never a host trusted in Settings → Models. `companionTokenRejected` is the one sentence for a companion
  401, in the player and in Settings → Voices.
- `Voice/VoiceMessageExporter.swift` (plan 022 Step 5): the `VoiceMessageProducing` behind Share → Voice message and
  a Create chain's voice message. Same chunks, voice and routing as `VoicePlayer` (before every chunk and retry, on
  `currentPrivacyClass`, raised never lowered); chunks are synthesized **in order, one at a time**, into
  `tmp/voice-message-<uuid>/chunk-<i>.<ext>`, then `VoiceMessageWriting` joins them (350 ms after a paragraph) and
  the file moves to `media/<itemID>/voice-<n>.m4a` (`nextNumber(in:)`; never overwrites). `phase`: `preparing`,
  `needsConfirmation`, `synthesizing(done:total:)` (real chunk counts), `assembling`, `finished(VoiceMessageFile)`,
  `failed(sentence)`; `retry()` resumes at the failed chunk (or re-joins), `cancel()` keeps nothing. **Only the
  app's dialog calls `confirmPendingSynthesis(requestID:)`**; `declinePendingSynthesis()` sends nothing; both fire
  `onAnswered`. `sweepStaleWork()` runs at launch. Tests: `VoiceMessageExporterTests`.
- `Voice/SpeechChunker.swift`: port of Readback's `Chunker` (NLTokenizer sentences; first chunk ≤ 500 characters,
  later ≤ 2 500, never above the engine's `maxCharactersPerRequest`; paragraph ends tagged).
- `Voice/SpeakableText.swift`: what Listen hands to `VoicePlayer`: citation timestamps, Markdown markers and link
  targets removed, a full stop after heading and list lines; words never changed.
- `Voice/VoiceProviderKind.swift`: the two voice providers (Mac companion, Grok voices) and their engine ids.
- `Voice/VoiceSettings.swift`: `VoiceSettings` (provider, companion voice and style, Grok stock voice, a free-text
  Voice ID that wins over it, Speak Ask answers; no secret), `UserDefaultsVoiceSettingsStore`
  (`ichirp.voiceSettings`), `VoiceEngineProviding` (the app builds engines over `ChirpEngineVoiceHTTP`; the companion
  is pinned per utterance), `VoiceSecrets.xaiAccount` (Keychain account, equal to `XAIVoice.secretAccount`), and
  `VoiceSettings.selection(engines:)` (a `notConfigured` sentence when a choice is missing).
- `Voice/VoiceSettingsViewModel.swift`: Settings → Voices. Companion state and voices (first voice picked when none
  is), the xAI key saved to the Keychain only (paste artifacts stripped, field cleared) with Check key
  (`GET /v1/api-key`), `setupProblem` for honest Listen hints, and Test voice (a fixed synthetic sentence through
  `VoicePlayer`, class general).

## Structure models (M6, `Structure/`; plan 015, contract [structure-model-plugin-v1](../../../spec/contracts/structure-model-plugin-v1.md))

- `Structure/StructureCatalog.swift`: `JSONValue`, `StructureTool`, `StructureCatalog` (frozen, versioned catalogs
  loaded from `Resources/StructureCatalogs/`: `soap-meds.v1`, `dictation-commands.v1`; `toolsJSON` is what a model
  reads, without the spoken `phrases`), `StructuredCall` (parse a call array; `problems(against:)` names unknown
  tools, missing required arguments and values outside an enum). A test pins each catalog file's SHA-256: a change
  ships as a new version file.
- `Structure/StubStructureModel.swift`: the rule-based **STUB** engine (`stub.rules`) for both catalogs, with a
  pseudo-confidence (at most 0.84 on `soap-meds`, and `StructuredResultGate.verdict(…engineID:)` never gives a STUB
  field `act`; a hedge like "considering" before a drug wins over a later "starting"; "no longer taking" is stopped,
  and "denies taking", "not taking", "never took" or "no" right before a drug record no medication); always
  available and always
  labelled STUB. `VoiceCommandText` (a command is a whole short
  utterance that equals one of its phrases, optionally after "okay"/"please").

- `Structure/StructuredResultGate.swift`: `StructureSettings` (voice commands off by default, gate thresholds,
  engine choice; its own UserDefaults key; the gate never below act 0.70 / provisional 0.50) and its stores; `StructuredResultGate` (act ≥ 0.85, provisional ≥ 0.60,
  else needs review; any problem forces needs review); `StructuredCallValidator` (per sentence: maps tags back to the
  normalizer's values, traces digits a model copied, **re-reads every number independently of the normalizer**
  (`IndependentNumberCheck.swift`: regex digits, spell-out `NumberFormatter`, its own unit list, plus the words right
  around the tag; a spoken number is re-read whole across "and" / "a", so "a hundred and" before a "twenty-five
  micrograms" tag reads as 125 and disagrees; a range in or around a tag's words, "4 to" before it or "to 120"
  after it, is never one value; a tablet or puff count other than one, or a fraction, near a strength forces
  review; a slash pair right before a dose unit is a combination strength, and a pressure needs a pressure word), range-checks vitals, doses by unit and frequencies, checks a dose sits next to its own drug (`owner(of:)`: the drug
  right before it, or right after it across only "of" or a route; a dose followed by "of <other word>" or right before
  a drug with its own dose goes to review; re-review I2-R) and a
  vital is not a drug's strength, carries any flagged tag or spoken correction to every call from the sentence, checks
  numbers in free text against the sentence, drops unknown or non-text arguments, flags drug or substance names
  missing from the sentence and schema problems; a number that traces to nothing is a numeric hard fail).
- `Structure/CrossSentenceCorrection.swift` (re-review N1): a correction said in the **next** sentence ("Gave fentanyl
  50 micrograms IV. Sorry, 25 micrograms."). `cues` is the named cue list (every in-sentence cue plus "no wait", "i
  misspoke", "let me correct"; a sentence starting "No," before a number or unit also counts). A sentence with a cue
  sends every field of the sentence before it to needs review ("Corrected in the next sentence …"); a dose it restates
  without a drug is named in the previous medication fields ("… restates a dose without a drug (25 mcg) …") and never
  applied. The extraction service and the eval runner apply the same rule.
- `Structure/StructuredSourceText.swift`: the run's source text (words joined from the word timestamps, else the
  text), sentence ranges (`NLTokenizer`), and character range → `StructuredSourceSpan` (transcript word indices and
  milliseconds).

- `Structure/StructuredExtractionService.swift`: `StructureEngines` (Needle handed over as `any StructureModel` with an
  availability closure; the STUB runs, and says why, when Needle cannot), `StructuredDraft`, and the
  `StructuredExtractionService` actor: sentence by sentence → normalizer → engine (`soap-meds.v1`) → validator →
  gate → a correction in the next sentence (`CrossSentenceCorrection`) → one run with its fields saved to the
  ledger. **Clinical items only reach `.onDevice` engines**
  (`mayRun`); engine failures become needs-review items, never silent gaps.
- `Structure/ExtractFieldsViewModel.swift`: `DraftItem` (with the whole evidence sentence and the value's highlight,
  editable values, edited flag) / `DraftSections` (vitals, medications, allergies, problems, plan, the needs-review
  bin, skipped sentences), `SOAPDraftHandoff` (**only reviewed fields** as `{{userNotes}}` for the SOAP template,
  always the on-device model; an accepted-despite or edited field carries its reasons) and `ExtractFieldsViewModel`
  (extract, load the latest run, mark reviewed; a field that failed a check opens `reviewRequest` instead, and
  `confirmReview(_:edits:)` saves edits; engine badge with Needle's experimental label; `menuTitle`).
- `Structure/StructureSettingsViewModel.swift`: Settings → Structure models (Needle's download and delete, engine,
  thresholds) and `NeedleExperimental` (the latest eval numbers and the "Experimental" chip and sentence every Needle
  surface shows until argument accuracy reaches 0.9).

- `Structure/VoiceCommandResolver.swift`: `dictation-commands.v1` on the **final pass**: a command is a whole sentence
  (≤ 8 words; abbreviations such as "p.o.", "t.i.d.", "mg.", "Dr." do not end a sentence unless a capital follows,
  and a capitalized dosing acronym after one, "p.o. TID.", never does; "No." ends a sentence unless a digit follows)
  equal to one of its phrases **and** confirmed by the engine at the act threshold; its sentence is
  removed and the edit applied (new paragraph / line, bullet list, scratch that, undo, capitalize). A sentence split
  from the one before only after an abbreviation in `continuingAbbreviations` ("500 mg. Three times daily.") is part
  of the same order, so "scratch that" removes back through it and "undo" restores it whole (re-review I9-R); read back and send
  to SOAP / Transform become actions after the copy. The same words inside a longer sentence and low-confidence
  answers change nothing. `liveCommand(in:)` checks the live preview's trailing words for a chip only.
- `Dictation/DictationVoiceCommands.swift` (M6): `ReadBackSpeaking` (`readBack(_:transcriptionID:)`; the app connects
  a `ReadBackRelay` to plan 020's `VoicePlayer` with source `.dictationReadBack(id:)`, so every chunk routes on that
  dictation's effective class; `SilentReadBack` is the unconnected default), `DictationVoiceCommanding` (the coordinator's hooks)
  and `DictationVoiceCommands` (off by default; the live chip after a 0.9 s pause, chip only, even for "stop"; the
  final-pass resolution; the pending Transform, cleared on reset; `appliedSummary` names STUB or "Experimental";
  dictation is routed as clinical, so command words only reach on-device engines). `DictationCoordinator` calls it at three points: reset, live text (chip only) and the copy.

- `Structure/OrderedJSON.swift`: JSON that keeps key order; the model-facing tool array is the catalog file's own
  order (Needle answered differently, and worse, when the schema keys were sorted).
- `Structure/StructureEval.swift` (Step 8, the Needle Bench Eval): the bundled synthetic sets
  (`Resources/StructureCatalogs/eval-soap-meds.v1.json`: 8 invented encounters, 48 sentences;
  `eval-dictation-commands.v1.json`: 30 utterances, 10 of them dictated text), `StructureEvalScorer` (tool-shape
  accuracy, argument accuracy, field exact match and the numeric hard-fail count, kept separate; commands: gated and
  ungated engine accuracy, feature accuracy, dictation eaten as a command), `StructureEvalRunner` (the same
  normalizer, validator and gate as the screens; normalizer on/off) and `StructureEvalReport`
  (`ichirp.structure-eval/v1` JSON and the "Copy for LLM" Markdown).
- `Structure/StructureEvalViewModel.swift`: Settings → Structure models → Eval (run the STUB or Needle, save each run
  to `structured_eval_runs`, export).

## ASR benchmark (M7 Step 6, `Benchmark/`)

- `ASRBenchmark.swift`:
  - `ASRBenchmarkItem`; `ASRBenchmarkReferenceSet`, which reads `asr-benchmark-reference.json` written by
    `scripts/make_benchmark_audio.sh` and bundled from `App/Resources/Benchmark`.
  - `ASRBenchmarkEngine`, `ASRBenchmarkResult` and `ASRBenchmarkRun`, whose per-engine `summaries` give corpus WER,
    total audio ÷ total time as a real-time factor, load time and peak memory.
  - `ASRBenchmarkRunner`:
    - It normalizes each recording once, then for each engine: unload (`SpeechEngineUnloading`), then each recording
      inside `SpeechJobScheduler.run(.fileTranscription)`, then unload again. Every engine and every job runs one at a
      time with the app's other jobs.
    - `prepare` is timed once per engine, as load time after the unload.
    - Peak physical footprint is sampled every 100 ms by an injected reader (`MemoryProbe` in the app).
    - Privacy routing runs first: the synthetic set is `.general`, and a person's own file is treated as `.clinical`.
      An engine without its model is reported, never downloaded.
    - A person's own file keeps no recognized text.
  - `ASRBenchmarkExport`: CSV (RFC 4180) and JSON (`ichirp.asr-benchmark/v1`).
- `ASRBenchmarkStore.swift`: an actor holding one JSON file (`<library>/benchmarks/asr-benchmark-runs.json`) with the
  newest 20 runs. Before saving, it strips text from results without a reference. There is no database table and no
  migration.
- `ASRDeviceBenchmark.swift` (fix/asr-review, DEBUG use): the controller's on-device run.
  - `ASRDeviceBenchmarkRequest.parse` reads `-ChirpBenchmarkDevice parakeet,whisper-base,whisper-turbo,apple-speech`
    (or `all`; order kept, repeats dropped, an unknown name is a readable failure).
  - `ASRDeviceBenchmark.run` skips an engine not in the build, over the memory budget, unavailable here, or waiting
    on a system permission prompt (`SpeechEnginePermissionReporting`: `permission-needed`, never waits on UI);
    downloads a missing model (the one download without a tap, asked for by the launch argument); then runs
    `ASRBenchmarkRunner` over the synthetic set. It never reads or changes the saved routes.
  - `ASRDeviceBenchmarkReport` (`ichirp.asr-device-benchmark/v1`): status, device model, build and commit, one line
    per engine (outcome, reason, WER, × real time, load, peak memory, download time) and the full run. The app writes
    it to `Documents/asr-device-benchmark.json` (`App/Sources/Debug/DeviceBenchmarkLaunch.swift`) and
    `scripts/device_benchmark.sh` reads it.
- `ASRBenchmarkViewModel.swift`: the Benchmark screen.
  - Engine choices with the reason an engine cannot run; ready engines are selected by default.
  - The reference-set toggle, and added files copied from the importer. Review M6: a person's file is labelled "Your
    file n" and copied under a neutral name (a file name can hold a patient's name); the copies are deleted when a
    run ends and at launch (`removeLeftoverImports`). `ASRBenchmarkStore` also replaces a file name an earlier build
    saved (items with a UUID id) when it reads the file.
  - Run and cancel, progress, saved history, and `exportFiles(to:)` for the share sheet.

## Number fidelity (on-device language models, review I2, `Benchmark/NumberFidelity.swift`)

- `NumberFidelity.check(note:required:source:)` → `NumberFidelityReport`: required numbers missing from a generated
  note (verbatim, with the dose unit), and numbers in the note the source never had (how an altered digit shows up).
- `SyntheticNumberVisit`: an invented, clinical pneumonia visit dense in repeated digits (500 mg, 1000 units, 118/76,
  0.05 mg, 100.0 F, 1 1/2 tablets, …), all written in digits. Used by the opt-in real-model test in
  `ChirpEngineLlamaCppTests` and the app's DEBUG `-ChirpLLMSmoke` runner, so the Mac and the phone check the same
  thing. Tests: `NumberFidelityTests`.

## Wiring (app composition root)

M7: `speech` below is the app's `SpeechEngineRouter` (`AppSpeechEngines.makeRouter`), not Parakeet itself. Parakeet,
Apple Speech and WhisperKit are registered in it, and the routes are saved in `UserDefaultsSpeechRouteStore`.

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

- **Speech routes (M7).**
  - Every consumer takes its route's engine once, when the job is queued: `SpeechRouting.resolve(self.speech, for:)`.
    It then uses that engine for the whole job: routing check, `prepare`, `transcribe` and the stored `engine` id. A
    route change applies to the next job only.
  - `.final`: `FileTranscriptionPipeline.run`, the dictation final pass and `MeetingFinalizer.run`.
  - `.live`: the dictation preview (through the router's `makeLiveSession`) and `MeetingCoordinator`'s live text.
  - A meeting holds the router's lease from `start()` until its state is finished (saved, failed or idle).
  - A missing model on the resolved engine fails the job with `SpeechModelMissingError`, which names that engine and
    says what to do (review I2). Retry resolves the route again, so switching Transcripts recovers.
  - `MeetingCoordinator` sends pause, resume, mute and the microphone restart through one chain of tasks
    (`sendToRecorder`), so they reach the recorder in order; stop and discard wait for the chain first.

- **Privacy routing runs before any engine gets audio** (ADR-002, `spec/12-privacy.md`). `run` asks
  `PrivacyRoutingPolicy` (injected, default: no trusted LAN hosts) whether the speech engine's locality may process
  the item's `privacyClass`, first at the start of the job, so refused audio is never even prepared, and again
  inside the scheduler slot against the class as stored at that moment, because the user may change it while the
  job waits. A refused speech engine fails the row with `PipelineError.privacyRoutingRefused`; a refused diarizer is
  skipped and logged (speaker labels are optional). On-device engines always pass. Logs carry the id, engine id,
  locality and class, never content. M1 has no per-run cloud override. Copy this pattern at every new engine call
  site (M4 language models, M6 structure models).
- **The pipeline never downloads.** If `speech.assetStatus()` is not `.ready`, or `prepare`/`transcribe` throws
  `SpeechEngineError.modelNotDownloaded`, the row fails with `SpeechModelMissingError`'s sentence: for Parakeet
  `FileTranscriptionPipeline.modelMissingMessage` ("Download the Parakeet speech model in Settings → Speech model"),
  for another engine a route chose its name and "Download it in Settings → Speech engines, or switch Transcripts to
  Parakeet". A diarizer that is not ready is skipped and
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

## Decision models (M6a, `Decisions/`, plan 021)

- `DecisionService.swift`: **the only path from a transcript to a `DecisionModel`** (contract
  `spec/contracts/decision-model-plugin-v1.md`; `DecisionServiceTests.testOnlyDecisionServiceCallsDecide` scans
  ChirpFeatures and `App/Sources` for other `.decide(` calls). `run(recipe:transcriptionID:)`: Jev off →
  `DecisionError.disabled` (no row); load the transcript; route with its `EffectivePrivacyClass`: **a clinical item
  returns `.blockedClinical` with a `refused` ledger row, no key read and nothing sent** (no override for decision
  engines in v1), and a routing-policy refusal returns `.blockedByRouting` the same way (`routing_refused`); window;
  read the key (a Keychain error or no key → a `failed` row); one `decide` after re-reading the effective class as
  stored now (a deleted transcript → `transcriptNotFound`, nothing sent); the gate; one metadata-only `llm_runs` row
  (`feature = decision`, `engineId = http.jev`, excerpt length, the provider's token counts, `callCount` 1 once
  `decide` was called except for its pre-send size check, else 0) whatever the outcome.
- `DecisionInputWindow.swift`: `excerpt` (the first 3,000 characters cut back to a sentence end, or to a space when
  the only sentence end is in the first third), `paragraphs(of:)` (the Transcript screen's paragraphs),
  `paragraphExcerpt` (`p01: …` lines for at most 12 paragraphs, fewer when they are long) and content-free `facts`
  (`duration_seconds`, `speaker_count`, `paragraph_count`, `source` = audio/document/link). Nothing else is sent.
- `DecisionRecipe.swift`: `recordingKind` (`kind`: meeting, dictation, lecture_or_talk, interview,
  clinical_encounter, other), `templateSuggestion` (`template`: the nine built-in keys plus `none`) and
  `paragraphTags` (`p01`…`p12`: action_item, decision, question, statement). Instructions say the text is untrusted.
- `DecisionOutcome.swift`: `DecisionGate` (`act` ≥ 0.80, `suggest` ≥ 0.55, else `unsure`; the one place the
  thresholds live, set from the live eval's calibration table), `DecisionVerdict`, `DecisionItem`, `DecisionReport`
  (consequences as suggestions: `suggestsMarkingClinical`, `suggestedTemplateKey`, session-only `paragraphTags`),
  `DecisionOutcome`, `DecisionError`.
- `JevSettingsStore.swift`: `JevSettings` (toggle, pinned model `jev-1.13.0`, TypeSafe's address unless the DEBUG
  `-ChirpJevBaseURL` override), `JevSettingsStoring` / `JevSettingsStore` (toggle and model in `UserDefaults` under
  `ichirp.jevSettings`; **the key only in the Keychain** under `structure.provider.jev.api-key`, written first), and
  `DecisionModelFactory` (the app's `AppDecisionModelFactory` is the only importer of `ChirpEngineJev`).
- `JevSettingsViewModel.swift`: Settings → Models → Decision models (`setEnabled`, `saveKey`, `testConnection`,
  `isMenuVisible`). `keyText` always starts empty and a blank field keeps the stored key; the key itself never enters
  the view model; `refresh()` also clears the last check, and `discardTypedKey()` (the sheet closed without saving)
  forgets a typed key. `DecisionRunViewModel.swift`: one decision for the result sheet (`running` → `decided` /
  `blocked` / `failed` with Retry; `cancel()` when the sheet closes); `failedAfterSending` tells the sheet whether an
  excerpt may have left the phone before the error. `DecisionReport.suggestsMarkingClinical` offers the raise whenever
  "clinical encounter" is Jev's top choice, at any confidence. App tests: `AppTests/DecisionModelAppTests`.

## Create: anything in, anything out (plan 022, `Create/`)

Plan: `docs/plans/2026-09-22-022-create-anything-in-anything-out.md`.

- `Create/TextItemService.swift` (Step 1): typed or pasted text as a Library item. `save(_:privacyClass:)` trims the
  surrounding blank space, refuses empty text (`TextItemError.empty`, nothing stored) and text over
  `maxCharacters`, and inserts a `.completed` `.text` row (`rawTranscript` = the text, `derivedTitle` = the first
  line via `title(from:)`, no media, no engine). Contract: `spec/contracts/document-items-v1.md` (Text item). The row
  routes like any other through `EffectivePrivacyClass`; tests: `TextItemServiceTests`, `TextItemStoreTests`.
- `Create/CreateFlow.swift` (Step 2): the chain **input** (speak, type, link, file) → **transcribe** (the existing
  jobs) → **operation** (none, Summary or a template) → **output** (the item, the document, a voice message).
  `CreateRequest` = `CreateInput` + `CreateOutput` + the new item's class; `CreateFlowDependencies` are the existing
  services as closures (dictation, `TextItemService`, link and file jobs, `waitForItem`, `retryItem`) plus
  `DeliverableService` and a `VoiceMessageProducing` factory, so tests run every input × output with fakes. Stages
  report `pending/running/done/skipped/failed`; `phase` is `running`, `waitingForAnswer(stage)`, `finished`,
  `failed(stage, sentence)` or `cancelled`; `retry()` restarts at the failed stage and reuses an item already made.
  **The chain never confirms a clinical question:** the operation's `DeliverableRunViewModel` and the voice message
  ask through their own dialogs, and `onAnswered` resumes the chain. A new item is raised to the chosen class
  (`DeliverableService.setPrivacyClass`) before any later step. Logs carry the chain id, item ids, kinds and stage
  names only.
- `Create/VoiceMessageProducing.swift`: `VoiceMessageRequest`, `VoiceMessageFile`, `VoiceMessagePhase` and the
  `VoiceMessageProducing` protocol (Step 5's `VoiceMessageExporter`).
- `Create/CreateChoices.swift`: the Create sheet's last answers (`UserDefaultsCreateChoicesStore`,
  `ichirp.create.choices`; choices only, never text); `validated(templateIDs:)` drops a removed template.
- Step 4, Edit by voice: `DeliverableService.routeEdit(deliverableID:model:)` and `edit(deliverableID:instruction:spoken:
  model:override:)` (in `DeliverableService.swift`, the "Edits" section): routes like every run (the transcript's
  effective class raised by the document's), one model call with `Create/DocumentEditPrompt.swift`'s request (the
  document in `<document>` tags, the instruction after it), refuses a document that cannot go in and back out in one
  call (`documentTooLongToEdit`, nothing sent), and stores the result through `DeliverableVersionStoring` (the store
  must implement it, `versionsUnavailable` otherwise) as the next version. Ledger feature `edit`; the instruction is
  never logged or in the ledger. `DeliverableRunViewModel.Request.edit` drives it for a screen.
  `Create/SpokenInstructionRecorder.swift`: hold to speak; the dictation path's final pass (`.dictation` slot and
  purpose, Clean with custom words) on a temporary WAV that is deleted after; no row, no clipboard, on-device engines
  only; `DocumentVersionsViewModel` (newest first, current version, Restore appends). Tests: `EditByVoiceTests`.
- Support hooks (additive): `TranscriptionJobCenter.waitForJob(_:)` waits on a row's real job;
  `DeliverableRunViewModel.onAnswered` fires after the dialog's Send or Cancel. Tests: `CreateFlowTests`,
  `CreateSupportTests`.

## How to verify

```bash
scripts/check.sh ChirpFeaturesTests
```

The M4 tests on their own: `swift test --package-path ChirpKit --filter
"DeliverableService|MapReduceGenerator|DeliverableRunViewModel|SingleGenerationPath|BuiltInTemplates|LanguageModelProviderStore"`.
The M6a tests: `scripts/check.sh "DecisionServiceTests|JevSettingsStoreTests"`.
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
