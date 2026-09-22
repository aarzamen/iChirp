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
@MainActor @Observable public final class TranscriptionJobCenter {
    /// Progress of every running job, by transcription id. A job's entry disappears when it ends.
    public private(set) var progress: [UUID: JobProgress] = [:]
    /// The last import that failed before a row existed (unreadable or missing file), for an alert.
    public private(set) var lastImportError: String?

    /// Running jobs by an internal token (the transcription id is unknown until the import step returns).
    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var tokenByJob: [UUID: UUID] = [:]
    /// The continued-processing bridge of each running job's user action, by job token.
    @ObservationIgnored private var continuationByToken: [UUID: BackgroundContinuation] = [:]
    @ObservationIgnored private let continuedProcessing: (any ContinuedProcessingScheduling)?
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
            continuationByToken[token]?.update(token, fraction: p.fraction, stage: p.stage.displayName)
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
    public func start(filesAt urls: [URL], pipeline: FileTranscriptionPipeline) {
        guard !urls.isEmpty else { return }
        let tokens = urls.map { _ in UUID() }
        let continuation = beginContinuation(title: Self.title(for: urls), tokens: tokens)
        for (url, token) in zip(urls, tokens) {
            startJob(fileAt: url, token: token, continuation: continuation, pipeline: pipeline)
        }
    }

    private func startJob(
        fileAt url: URL,
        token: UUID,
        continuation: BackgroundContinuation?,
        pipeline: FileTranscriptionPipeline
    ) {
        continuationByToken[token] = continuation
        tasks[token] = Task { @MainActor [weak self] in
            let id: UUID
            do {
                id = try await pipeline.importFile(from: url)
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
