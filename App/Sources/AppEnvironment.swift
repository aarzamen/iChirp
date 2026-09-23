import ChirpAudio
import ChirpCore
import ChirpEngineFluidAudio
import ChirpEngineVoiceHTTP
import ChirpExport
import ChirpFeatures
import ChirpIngest
import ChirpKeychain
import ChirpStore
import Foundation
import Observation

/// The composition root: builds every concrete store, engine and view model once, and owns launch housekeeping.
///
/// Engines are built once, here, from the saved settings. A Parakeet version change in Settings is saved and takes
/// effect the next time the app starts (`runningVariant` is what is loaded now).
@MainActor @Observable final class AppEnvironment {
    let paths: AppPaths
    let store: GRDBTranscriptionStore
    let speechEngine: ParakeetEngine
    let diarizer: FluidAudioDiarizer
    let scheduler: SpeechJobScheduler
    let settings: UserDefaultsSettingsStore
    /// The one owner of the audio session: dictation and the transcript player go through it (M2).
    let audioSession: AudioSessionController
    /// The one microphone stream per process (M2).
    let microphone: SharedMicrophoneStream
    /// Dictation: microphone → live preview → final Parakeet pass → clipboard (M2).
    let dictation: DictationCoordinator
    /// Custom words and snippets (M2): the editor in Settings → Text; Clean reads them for files and dictations.
    let textRules: TextRulesViewModel
    /// The dictation Live Activity (M2), driven by the coordinator's state.
    let liveActivity: DictationLiveActivity
    // M3 meetings (plan 012, spec/contracts/meeting-session-v1.md).
    /// One per launch: stamps and recognizes this launch's `recording.lock` files.
    let meetingLocks: MeetingSessionLockStore
    let meetingFinalizer: MeetingFinalizer
    /// The Meeting screen's model: microphone → `meeting.caf` + live text → final pass.
    let meeting: MeetingCoordinator
    let meetingRecovery: MeetingRecoveryService
    let meetingSettings: MeetingSettingsViewModel
    let meetingLiveActivity: MeetingLiveActivity
    let meetingBackground: MeetingBackgroundWork
    /// Meetings a killed or crashed launch left behind (the recovery sheet and the Library banner).
    private(set) var pendingMeetingRecoveries: [PendingMeetingRecovery] = []
    /// Ids being recovered now (the sheet shows their progress).
    private(set) var recoveringMeetings: Set<UUID> = []
    /// How each recovery this launch ended, for the sheet (title, sentence, whether the transcript was saved).
    private(set) var meetingRecoveryOutcomes: [UUID: (title: String, message: String, succeeded: Bool)] = [:]
    /// The recovery sheet is up (shown once at launch when something is pending; the Library banner reopens it).
    var isMeetingRecoveryPresented = false
    let jobCenter: TranscriptionJobCenter
    let pipeline: FileTranscriptionPipeline
    let library: LibraryViewModel
    let capture: CaptureViewModel
    let speechSettings: SpeechSettingsViewModel
    /// Where iOS copies files other apps hand to Parakeet (nil only if the Documents folder cannot be found).
    let inbox: IncomingFileInbox?
    /// M5: podcast, media and YouTube links (network only on the person's Transcribe or Retry).
    let linkIngest: LinkIngestService
    /// M5: PDF, Word, RTF, HTML, Markdown and text documents, read on this iPhone.
    let documents: DocumentImportPipeline
    /// Plan 019: Settings → Mac companion (host, port, trusted in UserDefaults; pairing token only in the Keychain).
    /// The `CompanionConfiguration` plan 020's voices read; YouTube audio uses its client.
    let companionSettings: CompanionSettingsStore
    /// Submits the background keep-alive requests for user-started jobs and downloads (M1.5).
    let continuedProcessing: SystemContinuedProcessingScheduler?
    /// The Parakeet version the speech engine was built with.
    let runningVariant: ParakeetVariant
    /// M4: providers from Settings → Models (metadata in UserDefaults, API keys only in the Keychain).
    let providerStore: UserDefaultsLanguageModelProviderStore
    /// M4: templates, generated documents and the content-free run ledger.
    let deliverableStore: GRDBDeliverableStore
    /// M4: **the only path from a transcript to a language model** (routing, clinical confirmation, ledger).
    let deliverables: DeliverableService
    /// M4: Settings → Models and the model Transform and Ask start with.
    let languageModels: LanguageModelsViewModel
    /// M4: the Transforms tab's templates and recent documents.
    let deliverableLibrary: DeliverableLibraryViewModel
    /// M6a (plan 021): Jev's toggle and model (UserDefaults) and API key (Keychain only).
    let jevSettings: JevSettingsStore
    /// M6a: **the only path from a transcript to a decision model**; clinical items are refused outright.
    let decisions: DecisionService
    /// M6a: Settings → Models → Decision models, and whether the Transcript shows the Jev menu.
    let jevSettingsModel: JevSettingsViewModel
    // Plan 020: voices (Listen, spoken Ask answers, dictation read-back).
    /// The Mac companion's address and pairing token: the same store as Settings → Mac companion (plan 019).
    let companionConfiguration: any CompanionConfiguration
    let voiceEngines: AppVoiceEngines
    /// **Reads text aloud**; routes every chunk (clinical → trusted Mac, or a per-reading confirmation for the cloud).
    let voicePlayer: VoicePlayer
    /// Settings → Voices.
    let voiceSettings: VoiceSettingsViewModel
    /// False until launch housekeeping has run and the model status has been read once (so Capture does not flash
    /// the "download the model" banner before it knows).
    private(set) var isLaunched = false
    #if DEBUG
    let smoke = SmokeTestRunner()
    #endif

    @ObservationIgnored private var launchTask: Task<Void, Never>?
    @ObservationIgnored private let logger = Log.logger("launch")

    /// Opens the database and builds the engines and view models. Throws only when the app's folder or database
    /// cannot be opened; nothing is deleted on failure.
    init(paths: AppPaths) throws {
        self.paths = paths
        let database = try DatabaseManager(url: paths.databaseURL)
        let store = GRDBTranscriptionStore(database: database)
        let textRulesStore = GRDBTextRulesStore(database: database)
        let settings = UserDefaultsSettingsStore()
        let settingsValue = settings.load()
        let engines = FluidAudioEngines.makeDefault(settings: settingsValue)
        let scheduler = SpeechJobScheduler()
        let continuedProcessing = SystemContinuedProcessingScheduler()
        let jobCenter = TranscriptionJobCenter(continuedProcessing: continuedProcessing)
        self.continuedProcessing = continuedProcessing
        let audioSession = AudioSessionController(platform: LiveAudioSessionPlatform.shared)
        self.audioSession = audioSession
        let microphone = SharedMicrophoneStream(engine: AVAudioEngineMicrophone(), session: audioSession)
        self.microphone = microphone
        self.store = store
        self.settings = settings
        self.runningVariant = settingsValue.parakeetVariant
        self.speechEngine = engines.speech
        self.diarizer = engines.diarizer
        self.scheduler = scheduler
        self.jobCenter = jobCenter
        let normalizer = AVAudioNormalizer()
        self.pipeline = FileTranscriptionPipeline(
            paths: paths,
            store: store,
            normalizer: normalizer,
            trackProbe: normalizer,
            speech: engines.speech,
            diarizer: engines.diarizer,
            scheduler: scheduler,
            settings: settings,
            customWords: { (try? await textRulesStore.enabledCustomWords()) ?? [] },
            onProgress: jobCenter.progressHandler
        )
        self.dictation = DictationCoordinator(
            capture: DictationRecorder(stream: microphone, session: audioSession),
            speech: engines.speech,
            liveSessions: engines.speech,
            scheduler: scheduler,
            store: store,
            paths: paths,
            settings: settings,
            clipboard: SystemClipboard(),
            textRules: { await DictationTextRules.enabled(in: textRulesStore) }
        )
        self.textRules = TextRulesViewModel(store: textRulesStore)
        let voiceActivity = FluidAudioEngines.makeVoiceActivity()
        let meetingLocks = MeetingSessionLockStore(paths: paths)
        let meetingBackground = MeetingBackgroundWork(scheduler: continuedProcessing)
        let jobProgress = jobCenter.progressHandler
        let meetingFinalizer = MeetingFinalizer(
            paths: paths,
            store: store,
            normalizer: normalizer,
            speech: engines.speech,
            diarizer: engines.diarizer,
            scheduler: scheduler,
            settings: settings,
            lockStore: meetingLocks,
            customWords: { (try? await textRulesStore.enabledCustomWords()) ?? [] },
            onProgress: { id, progress in
                jobProgress(id, progress)
                Task { @MainActor in meetingBackground.progress(id, progress) }
            }
        )
        self.meetingLocks = meetingLocks
        self.meetingFinalizer = meetingFinalizer
        self.meetingBackground = meetingBackground
        self.meeting = MeetingCoordinator(
            recorder: MeetingRecorder(stream: microphone, session: audioSession),
            speech: engines.speech,
            voiceActivity: voiceActivity,
            scheduler: scheduler,
            store: store,
            paths: paths,
            lockStore: meetingLocks,
            finalizer: meetingFinalizer
        )
        self.meetingRecovery = MeetingRecoveryService(
            paths: paths, store: store, lockStore: meetingLocks, finalizer: meetingFinalizer, normalizer: normalizer)
        self.meetingSettings = MeetingSettingsViewModel(voiceActivity: voiceActivity, settings: settings)
        let meetingLiveActivity = MeetingLiveActivity()
        self.meetingLiveActivity = meetingLiveActivity
        let liveActivity = DictationLiveActivity(
            modelName: settingsValue.parakeetVariant == .v3 ? "Parakeet v3" : "Parakeet v2")
        self.liveActivity = liveActivity
        self.library = LibraryViewModel(store: store, paths: paths)
        self.capture = CaptureViewModel(store: store)
        self.speechSettings = SpeechSettingsViewModel(
            speech: engines.speech, diarizer: engines.diarizer, settings: settings)
        let dictation = self.dictation
        dictation.onStateChange = { [weak liveActivity, weak dictation] state in
            liveActivity?.update(for: state, recordedSeconds: dictation?.recordedSeconds ?? 0)
        }
        let ingestHTTP = IngestHTTPClient()
        let companionSettings = CompanionSettingsStore(secrets: KeychainSecretStore())
        self.companionSettings = companionSettings
        self.linkIngest = LinkIngestService(
            paths: paths, store: store, http: ingestHTTP, downloader: MediaDownloader(),
            podcasts: PodcastEpisodeResolver(http: ingestHTTP), captions: YouTubeCaptionFetcher(http: ingestHTTP),
            companion: { companionSettings.makeClient() }, onProgress: jobCenter.progressHandler)
        self.documents = DocumentImportPipeline(
            paths: paths, store: store, extractor: DocumentTextExtractor(), onProgress: jobCenter.progressHandler)
        let meeting = self.meeting
        meeting.onStateChange = { [weak meetingLiveActivity, weak meeting] state in
            meetingLiveActivity?.update(
                for: state, recordedSeconds: meeting?.recordedSeconds ?? 0, title: meeting?.displayName ?? "Meeting")
        }
        meeting.onFinalPass = { [weak meetingBackground, weak meeting] id, running in
            if running {
                meetingBackground?.begin(id, title: meeting?.displayName ?? "Meeting")
            } else {
                meetingBackground?.end(id, succeeded: true)
            }
        }
        let inbox = IncomingFileInbox.appDefault()
        self.inbox = inbox
        // M4. Routing reads the provider store at every check, so un-trusting a Mac stops the next call of a run.
        let providerStore = UserDefaultsLanguageModelProviderStore(secrets: KeychainSecretStore())
        let deliverableStore = GRDBDeliverableStore(database: database)
        self.providerStore = providerStore
        self.deliverableStore = deliverableStore
        self.deliverables = DeliverableService(
            transcripts: store, deliverables: deliverableStore, routingPolicy: { providerStore.routingPolicy() })
        self.languageModels = LanguageModelsViewModel(store: providerStore, factory: AppLanguageModelFactory())
        self.deliverableLibrary = DeliverableLibraryViewModel(store: deliverableStore)
        // M6a: Jev. `-ChirpJevBaseURL` (DEBUG only) points it at the QA stub; routing reads the same provider policy.
        let jevSettings = JevSettingsStore(
            secrets: KeychainSecretStore(), baseURLOverride: JevDebugLaunch.baseURLOverride())
        let decisionFactory = AppDecisionModelFactory()
        self.jevSettings = jevSettings
        self.decisions = DecisionService(
            transcripts: store, ledger: deliverableStore, routingPolicy: { providerStore.routingPolicy() },
            settings: jevSettings, factory: decisionFactory)
        self.jevSettingsModel = JevSettingsViewModel(store: jevSettings, factory: decisionFactory)
        // Plan 020. Routing reads the providers' trusted hosts and the companion's trust at every chunk.
        // Plan 019's Settings → Mac companion store is the voices' companion configuration (DEBUG: the voice tour's
        // `-ChirpQACompanion*` launch arguments replace it for that run, writing nothing).
        let companionConfiguration = CompanionDebugLaunch.configuration(store: companionSettings)
        let voiceSecrets = KeychainSecretStore()
        let voiceEngines = AppVoiceEngines(secrets: voiceSecrets, companion: companionConfiguration)
        let voiceSettingsStore = UserDefaultsVoiceSettingsStore()
        // The class is read from the store before every chunk (review L2 C1): marking a transcript clinical, or making
        // a clinical deliverable from it, stops the next chunk of a reading that is going to the cloud.
        let voicePlayer = VoicePlayer(
            player: SpeechPlaybackEngine(session: audioSession),
            selection: { try voiceSettingsStore.load().selection(engines: voiceEngines) },
            routingPolicy: { providerStore.routingPolicy().trusting(companionConfiguration.companionEndpoint()) },
            currentPrivacyClass: { source in
                await VoiceSourcePrivacy.current(for: source, transcripts: store, deliverables: deliverableStore)
            })
        self.companionConfiguration = companionConfiguration
        self.voiceEngines = voiceEngines
        self.voicePlayer = voicePlayer
        self.voiceSettings = VoiceSettingsViewModel(
            store: voiceSettingsStore, secrets: voiceSecrets, engines: voiceEngines, player: voicePlayer,
            stockXAIVoices: XAIVoice.stockVoices)
        // iOS's Inbox copy of a shared file is temporary: drop it once its import has settled.
        jobCenter.onImportSettled = { url in inbox?.removeIfInside(url) }
    }

    /// The process's one environment: the scene shows it, and the App Intents (Action Button, Control, Shortcuts) use
    /// it even when they launched the app before any scene existed.
    static let shared: AppLaunchState = make()

    /// Builds the environment in Application Support, or describes why it could not.
    static func make() -> AppLaunchState {
        do {
            return .ready(try AppEnvironment(paths: AppPaths.applicationSupport()))
        } catch {
            Log.logger("launch").fault(
                "environment_failed error_type=\(String(describing: type(of: error)), privacy: .public) error=\(error.localizedDescription, privacy: .private)"
            )
            return .failed(message: Formatting.message(for: error))
        }
    }

    // MARK: - Launch

    /// Runs once per process; later callers wait for the first run. Order matters: rows left `.processing` by a
    /// killed process become `.interrupted` before any new job can insert a row, then their temporary audio goes.
    func launch() async {
        if let launchTask {
            await launchTask.value
            return
        }
        let task = Task { await self.performLaunch() }
        launchTask = task
        await task.value
    }

    private func performLaunch() async {
        do {
            let interrupted = try await store.markStaleProcessingAsInterrupted()
            if interrupted > 0 {
                logger.notice("marked_interrupted count=\(interrupted, privacy: .public)")
            }
        } catch {
            logger.error(
                "mark_interrupted_failed error_type=\(String(describing: type(of: error)), privacy: .public)")
        }
        await pipeline.sweepOrphanedTemporaryAudio()
        // A dictation recorded by a process that was killed before stopping becomes an interrupted row (never deleted).
        await dictation.recoverOrphanedRecordings()
        // M3: retention (only the person's setting; never a locked or unfinished meeting), then meetings to recover.
        await MeetingAudioRetentionSweeper(paths: paths, store: store, lockStore: meetingLocks, settings: settings)
            .sweep()
        await refreshMeetingRecoveries(presentIfAny: true)
        ExportTempFiles.sweepStale()
        logger.notice("launch build=\(BuildIdentity.current.summary, privacy: .public)")
        await library.start()
        await capture.start()
        await speechSettings.refresh()
        await launchLanguageModels()
        isLaunched = true
    }

    /// M4: installs or upgrades the built-in templates, then reads the Transforms lists and the model state.
    private func launchLanguageModels() async {
        do {
            try await deliverables.installBuiltInTemplates()
        } catch {
            logger.error(
                "templates_install_failed error_type=\(String(describing: type(of: error)), privacy: .public)")
        }
        await deliverableLibrary.load()
        await languageModels.refresh()
    }

    // MARK: - Actions shared by screens

    /// Imports and transcribes each file as its own tracked job (after launch housekeeping, so a new row can never
    /// be swept up as interrupted).
    func importFiles(_ urls: [URL]) {
        Task {
            await launch()
            jobCenter.start(filesAt: urls, pipeline: pipeline)
        }
    }

    /// A file another app handed to Parakeet (Share sheet → Parakeet, Files → Open in). iOS has already copied it into
    /// `Documents/Inbox/`; it is imported like a picked file and that copy is deleted once the import settles.
    /// Parakeet declares no URL scheme, so anything but a file URL is ignored. M5: documents (PDF, Word, text…) go to
    /// the document path; audio and video to the transcription pipeline.
    func openIncoming(_ url: URL) {
        guard url.isFileURL else {
            logger.notice("open_url_ignored reason=not_a_file")
            return
        }
        let kind = IncomingFileInbox.kind(of: url)
        logger.notice(
            "open_url_file inbox=\(self.inbox?.contains(url) ?? false, privacy: .public) kind=\(kind == .document ? "document" : "media", privacy: .public)"
        )
        switch kind {
        case .document: importDocuments([url])
        case .media: importFiles([url])
        }
    }

    // MARK: - M5 ingest

    /// Reads each document as its own tracked job (after launch housekeeping, like `importFiles`).
    func importDocuments(_ urls: [URL]) {
        Task {
            await launch()
            jobCenter.start(filesAt: urls, importer: documents)
        }
    }

    /// The Paste a link sheet's model. A podcast or media link's row continues as a tracked job: the download (never in
    /// a speech-scheduler slot), then the unchanged file pipeline.
    func makeLinkImportViewModel() -> LinkImportViewModel {
        LinkImportViewModel(service: linkIngest) { [weak self] id, source in
            self?.startLinkJob(id, title: source.title ?? "Download") { linkIngest in
                await linkIngest.download(id: id, source: source)
            }
        }
    }

    /// Runs `download` then, once the file is in place, the transcription, as one tracked job with its own background
    /// request.
    private func startLinkJob(
        _ id: UUID, title: String, download: @escaping @Sendable (LinkIngestService) async -> LinkDownloadResult
    ) {
        let linkIngest = self.linkIngest
        let pipeline = self.pipeline
        jobCenter.startTracked(id, title: title) {
            await LinkIngestService.downloadThenTranscribe(await download(linkIngest)) {
                await pipeline.process(id: id)
            }
        }
    }

    /// Re-runs a failed, cancelled or interrupted row (a person's tap, so it also gets a background request titled
    /// after the row).
    func retry(_ id: UUID) {
        let item = library.items.first { $0.id == id }
        if let item, item.isDocument {
            // M5: a document re-reads its kept source.
            jobCenter.retry(id, title: item.displayTitle, importer: documents)
            return
        }
        if let item, LinkIngestService.needsDownload(item) {
            // M5: a link whose download never finished downloads again (resuming when the server allows), then
            // transcribes.
            startLinkJob(id, title: item.displayTitle) { linkIngest in await linkIngest.retryDownload(id: id) }
            return
        }
        if item?.sourceType == .meeting {
            // A meeting's retry is its own final pass (`.meetingFinalize`, custom words only, lock settlement).
            retryMeeting(id, title: item?.displayTitle ?? "Meeting")
            return
        }
        if item?.sourceType == .dictation {
            // A dictation's recording is already 16 kHz: the dictation final pass (no speaker labels), no clipboard.
            let dictation = self.dictation
            Task { await dictation.retry(transcriptionID: id) }
            return
        }
        let title = item?.displayTitle ?? "Transcription"
        jobCenter.retry(id, title: title, pipeline: pipeline)
    }

    // MARK: - Meetings (M3)

    /// Re-reads the meetings an earlier launch left behind; at launch the sheet opens when there are any.
    func refreshMeetingRecoveries(presentIfAny: Bool = false) async {
        let pending = await meetingRecovery.discoverPendingRecoveries()
        pendingMeetingRecoveries = pending.filter { !recoveringMeetings.contains($0.id) }
        if presentIfAny, !pendingMeetingRecoveries.isEmpty {
            isMeetingRecoveryPresented = true
        }
    }

    /// Recover: finalize with the captured route; the row appears in the Library ("Partial audio" when cut).
    func recoverMeeting(_ id: UUID) {
        guard !recoveringMeetings.contains(id) else { return }
        let title = pendingMeetingRecoveries.first { $0.id == id }?.displayName ?? "Meeting"
        recoveringMeetings.insert(id)
        meetingBackground.begin(id, title: title)
        let recovery = meetingRecovery
        Task {
            let saved = await recovery.recover(id)
            let succeeded = saved?.status == .completed
            meetingBackground.end(id, succeeded: succeeded)
            meetingRecoveryOutcomes[id] = (
                title,
                succeeded
                    ? "Recovered. The transcript is in the Library."
                    : (saved?.errorMessage ?? "It could not be transcribed yet.")
                        + " The recording is in the Library; tap Retry there.",
                succeeded
            )
            recoveringMeetings.remove(id)
            await refreshMeetingRecoveries()
        }
    }

    /// Discard (after the person confirmed in the sheet): the meeting's row and folder.
    func discardMeeting(_ id: UUID) async throws {
        try await meetingRecovery.discard(id)
        await refreshMeetingRecoveries()
    }

    private func retryMeeting(_ id: UUID, title: String) {
        meetingBackground.begin(id, title: title)
        let finalizer = meetingFinalizer
        Task {
            let saved = await finalizer.retry(id: id)
            meetingBackground.end(id, succeeded: saved?.status == .completed)
        }
    }

    // MARK: - Model downloads (Settings)

    func downloadSpeechModel() {
        let speech = speechSettings
        downloadModel(title: "Parakeet speech model") { onProgress in
            await speech.downloadSpeechModel(onProgress: onProgress)
        }
    }

    /// Settings → Meetings: the voice-activity model for live meeting text (about 2 MB).
    func downloadVoiceActivityModel() {
        let meetingSettings = self.meetingSettings
        downloadModel(title: "Voice activity model") { onProgress in
            await meetingSettings.downloadVoiceActivityModel(onProgress: onProgress)
        }
    }

    func downloadDiarizer() {
        let speech = speechSettings
        downloadModel(title: "Speaker model") { onProgress in
            await speech.downloadDiarizer(onProgress: onProgress)
        }
    }

    /// Runs a Settings Download tap under its own continued-processing request, so the download keeps going with the
    /// phone locked and shows in the system's progress UI; Cancel there cancels it. When the system refuses the request
    /// (the Simulator always does) it falls back to the M1 keep-alive (`DownloadKeepAlive`).
    private func downloadModel(
        title: String,
        _ download: @escaping @MainActor (_ onProgress: @escaping @MainActor (Double) -> Void) async -> Bool
    ) {
        let item = UUID()
        let continuation = BackgroundContinuation(
            scheduler: continuedProcessing, kind: .modelDownload, title: title, subtitle: "Downloading", items: [item])
        let submitted = continuation.begin()
        let task = Task { @MainActor in
            let ready: Bool
            if submitted {
                ready = await download { fraction in
                    continuation.update(item, fraction: fraction, stage: "Downloading")
                }
            } else {
                ready = await DownloadKeepAlive.shared.withKeepAlive { await download { _ in } }
            }
            continuation.end(item, succeeded: ready)
        }
        continuation.onExpiration = { task.cancel() }
    }

    /// Deletes a row and its audio after the user confirmed: cancels its job first, then deletes.
    func delete(_ id: UUID) async throws {
        jobCenter.cancel(id)
        try await library.delete(id)
    }

    func makeTranscriptViewModel(id: UUID) -> TranscriptViewModel {
        TranscriptViewModel(id: id, store: store, paths: paths, settings: settings)
    }

    /// M4: one generated document (Transforms tab, or a finished Transform run).
    func makeDocumentViewModel(id: UUID) -> DeliverableDocumentViewModel {
        DeliverableDocumentViewModel(id: id, store: deliverableStore)
    }

    /// Whether the speech model is on disk (the Capture banner shows when it is not).
    var isSpeechModelReady: Bool {
        if case .ready = speechSettings.speechStatus { return true }
        return false
    }
}

/// What the app shows at the root: the tabs, or an honest error when the library could not be opened.
enum AppLaunchState {
    case ready(AppEnvironment)
    case failed(message: String)
}
