import ChirpAudio
import ChirpCore
import ChirpEngineFluidAudio
import ChirpExport
import ChirpFeatures
import ChirpIngest
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
    /// Submits the background keep-alive requests for user-started jobs and downloads (M1.5).
    let continuedProcessing: SystemContinuedProcessingScheduler?
    /// The Parakeet version the speech engine was built with.
    let runningVariant: ParakeetVariant
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
        self.linkIngest = LinkIngestService(
            paths: paths, store: store, http: ingestHTTP, downloader: MediaDownloader(),
            podcasts: PodcastEpisodeResolver(http: ingestHTTP), captions: YouTubeCaptionFetcher(http: ingestHTTP),
            onProgress: jobCenter.progressHandler)
        self.documents = DocumentImportPipeline(
            paths: paths, store: store, extractor: DocumentTextExtractor(), onProgress: jobCenter.progressHandler)
        let inbox = IncomingFileInbox.appDefault()
        self.inbox = inbox
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
        ExportTempFiles.sweepStale()
        logger.notice("launch build=\(BuildIdentity.current.summary, privacy: .public)")
        await library.start()
        await capture.start()
        await speechSettings.refresh()
        isLaunched = true
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
                await linkIngest.download(id: id, from: source.downloadURL)
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
        if item?.sourceType == .dictation {
            // A dictation's recording is already 16 kHz: the dictation final pass (no speaker labels), no clipboard.
            let dictation = self.dictation
            Task { await dictation.retry(transcriptionID: id) }
            return
        }
        let title = item?.displayTitle ?? "Transcription"
        jobCenter.retry(id, title: title, pipeline: pipeline)
    }

    // MARK: - Model downloads (Settings)

    func downloadSpeechModel() {
        let speech = speechSettings
        downloadModel(title: "Parakeet speech model") { onProgress in
            await speech.downloadSpeechModel(onProgress: onProgress)
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
