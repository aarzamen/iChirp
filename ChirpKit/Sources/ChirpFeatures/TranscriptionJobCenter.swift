import ChirpCore
import Foundation
import Observation

/// The app's list of running file jobs: live progress for the UI, plus the `Task`s so a job can be cancelled.
///
/// Wire it before the pipeline: create the center, then pass `progressHandler` as the pipeline's `onProgress`.
/// The handler may be called from any thread; it hops to the main actor before touching state.
///
/// **Background (M1.5).** Given a `ContinuedProcessingScheduling`, every user action (`start(filesAt:)` with its
/// files, or one `retry`) also submits one continued-processing request, so the jobs keep running after the person
/// leaves the app, with the system's progress UI. The jobs start at once either way; the request is only a keep-alive
/// and a progress surface (`BackgroundContinuation`). When the system expires it (or the person taps Cancel in the
/// Live Activity), that action's jobs are cancelled: their rows end `cancelled`, never lost.
///
/// **Audio tracks (M1.5).** When the pipeline can list tracks, `start(filesAt:)` first checks every file. If any has
/// two or more audio tracks, nothing is imported yet: `pendingAudioTrackSelection` asks the person to choose, and
/// `selectAudioTrack(_:for:)` starts the batch with that choice for its multi-track files (single-track files stay
/// automatic), while `cancelAudioTrackSelection(_:)` drops the batch. Contract:
/// `spec/contracts/file-transcription-audio-tracks-v1.md`.
@MainActor @Observable public final class TranscriptionJobCenter {
    /// A choice the person must make before a batch with a multi-track file is imported.
    public struct AudioTrackSelectionRequest: Identifiable, Equatable, Sendable {
        public let id: UUID
        /// The first multi-track file's name; its tracks are the ones offered.
        public let fileName: String
        /// How many files the batch holds; the choice applies to each of its multi-track files.
        public let fileCount: Int
        public let tracks: [AudioTrackDescriptor]

        public var isBatch: Bool { fileCount > 1 }

        public init(id: UUID, fileName: String, fileCount: Int, tracks: [AudioTrackDescriptor]) {
            self.id = id
            self.fileName = fileName
            self.fileCount = fileCount
            self.tracks = tracks
        }
    }

    /// Progress of every running job, by transcription id. A job's entry disappears when it ends.
    public private(set) var progress: [UUID: JobProgress] = [:]
    /// The last import that failed before a row existed (unreadable or missing file), for an alert.
    public private(set) var lastImportError: String?
    /// The track choice the app must ask for now, or nil. Batches that arrive meanwhile wait their turn.
    public private(set) var pendingAudioTrackSelection: AudioTrackSelectionRequest?

    /// Running jobs by an internal token (the transcription id is unknown until the import step returns).
    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var tokenByJob: [UUID: UUID] = [:]
    /// The continued-processing bridge of each running job's user action, by job token.
    @ObservationIgnored private var continuationByToken: [UUID: BackgroundContinuation] = [:]
    @ObservationIgnored private let continuedProcessing: (any ContinuedProcessingScheduling)?
    /// Batches waiting for a track choice, oldest first; the first is `pendingAudioTrackSelection`.
    @ObservationIgnored private var pendingBatches: [PendingBatch] = []

    private struct PendingBatch {
        let request: AudioTrackSelectionRequest
        let urls: [URL]
        /// Indices into `urls` of the files with two or more audio tracks.
        let multiTrack: Set<Int>
        let pipeline: FileTranscriptionPipeline
    }
    /// Ids whose job ended. A progress hop that arrives after `finish` must not bring the entry back.
    @ObservationIgnored private var finished: Set<UUID> = []
    @ObservationIgnored private let logger = Log.logger("jobs")

    /// Called on the main actor once per file whose import attempt has settled: imported (the row exists), failed
    /// before a row existed, or never started. The app uses it to delete iOS's temporary `Documents/Inbox` copy
    /// (`IncomingFileInbox.removeIfInside`). Never called for a retry, which has no incoming file.
    @ObservationIgnored public var onImportSettled: (@MainActor (URL) -> Void)?

    /// - Parameter continuedProcessing: submits the background keep-alive requests; nil (tests, previews, or a
    ///   platform without them) runs every job in the foreground only, as in M1.
    public init(continuedProcessing: (any ContinuedProcessingScheduling)? = nil) {
        self.continuedProcessing = continuedProcessing
    }

    /// Pass to `FileTranscriptionPipeline(onProgress:)`. Callable from any isolation; updates arrive on the main actor.
    public nonisolated var progressHandler: @Sendable (UUID, JobProgress) -> Void {
        { [weak self] id, progress in
            Task { @MainActor [weak self] in
                self?.update(id, progress)
            }
        }
    }

    /// Clears `lastImportError` (the alert's dismiss action).
    public func dismissImportError() {
        lastImportError = nil
    }

    /// Records `p` for `id`, unless that job already finished, and forwards it to the job's background request.
    public func update(_ id: UUID, _ p: JobProgress) {
        guard !finished.contains(id) else { return }
        progress[id] = p
        if let token = tokenByJob[id] {
            continuationByToken[token]?.update(token, fraction: p.overallFraction, stage: p.stage.displayName)
        }
    }

    /// Clears `id`'s progress and stops tracking its task. Called when a job ends.
    public func finish(_ id: UUID) {
        finished.insert(id)
        progress[id] = nil
        if let token = tokenByJob.removeValue(forKey: id) {
            tasks[token] = nil
        }
    }

    /// Starts import+process as one tracked Task; keeps the Task so it can be cancelled.
    public func start(fileAt url: URL, pipeline: FileTranscriptionPipeline) {
        start(filesAt: [url], pipeline: pipeline)
    }

    /// Starts one tracked job per file, in order, for files the person handed over in one action (a multi-select
    /// pick, or a file shared from another app). Each file is its own row and its own job; the action gets one
    /// continued-processing request titled after the file (or "N files").
    ///
    /// When the pipeline can list audio tracks, every file is checked first; a batch with a multi-track file waits
    /// for `selectAudioTrack(_:for:)` before anything is imported. A file whose tracks cannot be read is imported as
    /// usual, and its job reports the real error on its row.
    public func start(filesAt urls: [URL], pipeline: FileTranscriptionPipeline) {
        guard !urls.isEmpty else { return }
        guard pipeline.canInspectAudioTracks else {
            launch(urls, audioTrackOrdinal: nil, multiTrack: [], pipeline: pipeline)
            return
        }
        let token = UUID()
        tasks[token] = Task { @MainActor [weak self] in
            var multiTrack: Set<Int> = []
            var offered: (url: URL, tracks: [AudioTrackDescriptor])?
            for (index, url) in urls.enumerated() {
                let tracks = (try? await pipeline.audioTracks(in: url)) ?? []
                guard tracks.count > 1 else { continue }
                multiTrack.insert(index)
                if offered == nil { offered = (url, tracks) }
            }
            guard let self else { return }
            self.tasks[token] = nil
            if let offered {
                let request = AudioTrackSelectionRequest(
                    id: UUID(), fileName: offered.url.lastPathComponent, fileCount: urls.count, tracks: offered.tracks)
                self.enqueue(PendingBatch(request: request, urls: urls, multiTrack: multiTrack, pipeline: pipeline))
            } else {
                self.launch(urls, audioTrackOrdinal: nil, multiTrack: [], pipeline: pipeline)
            }
        }
    }

    /// The person chose `ordinal` for the pending request `requestID`: starts that batch, with the choice for its
    /// multi-track files and automatic selection for the rest. A choice for a request no longer shown, or a track
    /// it does not offer, does nothing.
    public func selectAudioTrack(_ ordinal: Int, for requestID: UUID) {
        guard let batch = pendingBatches.first, batch.request.id == requestID,
            batch.request.tracks.contains(where: { $0.ordinal == ordinal })
        else {
            return
        }
        dequeue()
        logger.notice(
            "audio_track_chosen ordinal=\(ordinal, privacy: .public) files=\(batch.urls.count, privacy: .public) multi_track=\(batch.multiTrack.count, privacy: .public)"
        )
        launch(batch.urls, audioTrackOrdinal: ordinal, multiTrack: batch.multiTrack, pipeline: batch.pipeline)
    }

    /// The person dismissed the track choice for `requestID`: the whole batch is dropped (nothing was imported) and
    /// each file counts as settled, so the app can delete iOS's Inbox copies.
    public func cancelAudioTrackSelection(_ requestID: UUID) {
        guard let batch = pendingBatches.first, batch.request.id == requestID else { return }
        dequeue()
        logger.notice("audio_track_choice_cancelled files=\(batch.urls.count, privacy: .public)")
        for url in batch.urls {
            onImportSettled?(url)
        }
    }

    private func enqueue(_ batch: PendingBatch) {
        pendingBatches.append(batch)
        if pendingAudioTrackSelection == nil {
            pendingAudioTrackSelection = batch.request
        }
    }

    private func dequeue() {
        pendingBatches.removeFirst()
        pendingAudioTrackSelection = pendingBatches.first?.request
    }

    /// Starts the batch's jobs under one continued-processing request. `audioTrackOrdinal` applies only to the files
    /// at `multiTrack`; the others are automatic.
    private func launch(
        _ urls: [URL],
        audioTrackOrdinal: Int?,
        multiTrack: Set<Int>,
        pipeline: FileTranscriptionPipeline
    ) {
        let tokens = urls.map { _ in UUID() }
        let continuation = beginContinuation(title: Self.title(for: urls), tokens: tokens)
        for (index, (url, token)) in zip(urls, tokens).enumerated() {
            startJob(
                fileAt: url,
                audioTrackOrdinal: multiTrack.contains(index) ? audioTrackOrdinal : nil,
                token: token,
                continuation: continuation,
                pipeline: pipeline
            )
        }
    }

    private func startJob(
        fileAt url: URL,
        audioTrackOrdinal: Int?,
        token: UUID,
        continuation: BackgroundContinuation?,
        pipeline: FileTranscriptionPipeline
    ) {
        continuationByToken[token] = continuation
        tasks[token] = Task { @MainActor [weak self] in
            let id: UUID
            do {
                id = try await pipeline.importFile(from: url, audioTrackOrdinal: audioTrackOrdinal)
            } catch {
                self?.logger.error(
                    "import_failed error_type=\(error.logTypeName, privacy: .public) error=\(error.localizedDescription, privacy: .private)"
                )
                self?.lastImportError = Self.readable(error)
                self?.tasks[token] = nil
                self?.onImportSettled?(url)
                self?.endContinuation(token, status: nil)
                return
            }
            self?.track(id, token: token)
            self?.onImportSettled?(url)
            let row = await pipeline.process(id: id)
            self?.endContinuation(token, status: row?.status)
            self?.finish(id)
        }
    }

    /// Re-runs a failed, cancelled or interrupted row as a tracked job (see `FileTranscriptionPipeline.retry`).
    /// Does nothing while that row's job is still running. `title` names the row in the system's progress UI.
    public func retry(_ id: UUID, title: String = "Transcription", pipeline: FileTranscriptionPipeline) {
        guard tokenByJob[id] == nil else { return }
        let token = UUID()
        track(id, token: token)
        continuationByToken[token] = beginContinuation(title: title, tokens: [token])
        tasks[token] = Task { @MainActor [weak self] in
            let row = await pipeline.retry(id: id)
            self?.endContinuation(token, status: row?.status)
            self?.finish(id)
        }
    }

    // MARK: - Other importers and tracked work (M5)

    /// Starts one tracked job per file for an importer other than the audio pipeline (M5 documents), under one
    /// continued-processing request, exactly like `start(filesAt:pipeline:)` without the audio-track check: each file
    /// is imported (its row exists), reported to `onImportSettled`, then processed.
    public func start(filesAt urls: [URL], importer: any ItemImporting) {
        guard !urls.isEmpty else { return }
        let tokens = urls.map { _ in UUID() }
        let continuation = beginContinuation(title: Self.title(for: urls), tokens: tokens)
        for (url, token) in zip(urls, tokens) {
            continuationByToken[token] = continuation
            tasks[token] = Task { @MainActor [weak self] in
                let id: UUID
                do {
                    id = try await importer.importItem(from: url)
                } catch {
                    self?.logger.error("import_failed error_type=\(error.logTypeName, privacy: .public)")
                    self?.lastImportError = Self.readable(error)
                    self?.tasks[token] = nil
                    self?.onImportSettled?(url)
                    self?.endContinuation(token, status: nil)
                    return
                }
                self?.track(id, token: token)
                self?.onImportSettled?(url)
                let row = await importer.process(id: id)
                self?.endContinuation(token, status: row?.status)
                self?.finish(id)
            }
        }
    }

    /// Re-runs a failed, cancelled or interrupted row through `importer` (M5 documents), like `retry(_:title:pipeline:)`.
    public func retry(_ id: UUID, title: String, importer: any ItemImporting) {
        startTracked(id, title: title) { await importer.retry(id: id) }
    }

    /// Runs `work` as the tracked job of the existing row `id` (M5: a link's download followed by its transcription),
    /// with its own continued-processing request titled `title`. `work` returns the row as it ended (nil: gone); it
    /// is cancelled by `cancel(id)` or when the system expires the request. Does nothing while `id` has a job.
    public func startTracked(_ id: UUID, title: String, work: @escaping @Sendable () async -> Transcription?) {
        guard tokenByJob[id] == nil else { return }
        let token = UUID()
        track(id, token: token)
        continuationByToken[token] = beginContinuation(title: title, tokens: [token])
        tasks[token] = Task { @MainActor [weak self] in
            let row = await work()
            self?.endContinuation(token, status: row?.status)
            self?.finish(id)
        }
    }

    /// Cancels `id`'s job; the pipeline marks the row `.cancelled` and keeps the source file.
    public func cancel(_ id: UUID) {
        guard let token = tokenByJob[id] else { return }
        tasks[token]?.cancel()
    }

    /// Whether a job for `id` is running (queued, transcribing or finishing).
    public func isRunning(_ id: UUID) -> Bool {
        tokenByJob[id] != nil
    }

    /// Suspends until every job running now, and any started meanwhile, has ended.
    public func waitUntilIdle() async {
        while let (token, task) = tasks.first {
            await task.value
            // A finished job removes itself; this only guards against spinning on one that did not.
            tasks[token] = nil
        }
    }

    private func track(_ id: UUID, token: UUID) {
        finished.remove(id)
        tokenByJob[id] = token
    }

    // MARK: - Background continuation

    /// Submits one continued-processing request for a user action's jobs. Returns nil when there is no scheduler or
    /// the system refused the request (the jobs still run, in the foreground).
    private func beginContinuation(title: String, tokens: [UUID]) -> BackgroundContinuation? {
        guard let continuedProcessing else { return nil }
        let continuation = BackgroundContinuation(
            scheduler: continuedProcessing, kind: .transcription, title: title, subtitle: "Waiting to start",
            items: tokens)
        continuation.onExpiration = { [weak self] in
            self?.cancelTokens(tokens)
        }
        return continuation.begin() ? continuation : nil
    }

    /// Ends a job's item in its continuation: success only for a completed row (nil status: no row, e.g. a failed
    /// import or a row deleted during its job).
    private func endContinuation(_ token: UUID, status: Transcription.Status?) {
        guard let continuation = continuationByToken.removeValue(forKey: token) else { return }
        continuation.end(token, succeeded: status == .completed)
    }

    /// Cancels the given jobs (a user action's jobs, after its background request expired). Each row ends
    /// `.cancelled` through the pipeline, as with an in-app cancel.
    private func cancelTokens(_ tokens: [UUID]) {
        for token in tokens {
            tasks[token]?.cancel()
        }
        logger.notice("jobs_cancelled_on_expiration count=\(tokens.count, privacy: .public)")
    }

    /// The system progress UI's title: the file's name without its extension, or "N files".
    static func title(for urls: [URL]) -> String {
        guard urls.count == 1, let url = urls.first else { return "\(urls.count) files" }
        let name = url.deletingPathExtension().lastPathComponent
        return name.isEmpty ? "Transcription" : name
    }

    private static func readable(_ error: any Error) -> String {
        if let description = (error as? any LocalizedError)?.errorDescription, !description.isEmpty {
            return description
        }
        return error.localizedDescription
    }
}

/// An importer the job center can run besides the audio pipeline (M5: `DocumentImportPipeline`). The same shape as
/// `FileTranscriptionPipeline`: `importItem` copies the file in and creates the row (nothing is left behind when it
/// throws), `process` runs a `.processing` row to its end, `retry` moves a failed, cancelled or interrupted row back and
/// runs it again.
public protocol ItemImporting: Sendable {
    func importItem(from url: URL) async throws -> UUID
    func process(id: UUID) async -> Transcription?
    func retry(id: UUID) async -> Transcription?
}
