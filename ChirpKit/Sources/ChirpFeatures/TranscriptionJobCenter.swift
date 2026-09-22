import ChirpCore
import Foundation
import Observation

/// The app's list of running file jobs: live progress for the UI, plus the `Task`s so a job can be cancelled.
///
/// Wire it before the pipeline: create the center, then pass `progressHandler` as the pipeline's `onProgress`.
/// The handler may be called from any thread; it hops to the main actor before touching state.
@MainActor @Observable public final class TranscriptionJobCenter {
    /// Progress of every running job, by transcription id. A job's entry disappears when it ends.
    public private(set) var progress: [UUID: JobProgress] = [:]
    /// The last import that failed before a row existed (unreadable or missing file), for an alert.
    public private(set) var lastImportError: String?

    /// Running jobs by an internal token (the transcription id is unknown until the import step returns).
    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var tokenByJob: [UUID: UUID] = [:]
    /// Ids whose job ended. A progress hop that arrives after `finish` must not bring the entry back.
    @ObservationIgnored private var finished: Set<UUID> = []
    @ObservationIgnored private let logger = Log.logger("jobs")

    /// Called on the main actor once per file whose import attempt has settled: imported (the row exists), failed
    /// before a row existed, or never started. The app uses it to delete iOS's temporary `Documents/Inbox` copy
    /// (`IncomingFileInbox.removeIfInside`). Never called for a retry, which has no incoming file.
    @ObservationIgnored public var onImportSettled: (@MainActor (URL) -> Void)?

    public init() {}

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

    /// Records `p` for `id`, unless that job already finished.
    public func update(_ id: UUID, _ p: JobProgress) {
        guard !finished.contains(id) else { return }
        progress[id] = p
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

    /// Starts one tracked job per file, in order, for files the user handed over in one action (a multi-select
    /// pick, or a file shared from another app). Each file is its own row and its own job.
    public func start(filesAt urls: [URL], pipeline: FileTranscriptionPipeline) {
        for url in urls {
            startJob(fileAt: url, pipeline: pipeline)
        }
    }

    private func startJob(fileAt url: URL, pipeline: FileTranscriptionPipeline) {
        let token = UUID()
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
                return
            }
            self?.track(id, token: token)
            self?.onImportSettled?(url)
            await pipeline.process(id: id)
            self?.finish(id)
        }
    }

    /// Re-runs a failed, cancelled or interrupted row as a tracked job (see `FileTranscriptionPipeline.retry`).
    /// Does nothing while that row's job is still running.
    public func retry(_ id: UUID, pipeline: FileTranscriptionPipeline) {
        guard tokenByJob[id] == nil else { return }
        let token = UUID()
        track(id, token: token)
        tasks[token] = Task { @MainActor [weak self] in
            await pipeline.retry(id: id)
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

    private static func readable(_ error: any Error) -> String {
        if let description = (error as? any LocalizedError)?.errorDescription, !description.isEmpty {
            return description
        }
        return error.localizedDescription
    }
}
