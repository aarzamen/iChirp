import ChirpCore
import FluidAudio
import Foundation

/// A loaded runtime checked out for one inference, stamped with the generation it was loaded for.
/// Every `acquire()` must be paired with one `release(_:)`.
struct ModelLease<Runtime: Sendable>: Sendable {
    let runtime: Runtime
    let generation: Int
}

/// The download → load → use → delete lifecycle shared by the FluidAudio engines. It is the one place that decides
/// what may overlap (upstream `STTRuntime` uses an `initializationGeneration` for the same purpose):
///
/// - Only `download` touches the network. `prepare` and `acquire` load strictly from local files, and throw
///   `SpeechEngineError.modelNotDownloaded` while files are missing, while a download is in flight, or while a
///   delete runs.
/// - Concurrent callers join one download and one load.
/// - `delete` refuses while any lease is out. Otherwise it bumps the generation, cancels **and awaits** any
///   in-flight download and load, and only then removes files. A load that finishes for an older generation is
///   discarded, so a delete can never be undone by a load that was already compiling.
/// - A download requested during a delete waits for the delete to finish, then starts fresh.
actor ModelAssetLifecycle<Runtime: Sendable> {
    struct Hooks: Sendable {
        /// The engine's `EngineDescriptor.id`, carried by `.modelNotDownloaded` as the engine contract requires.
        var engineID: String
        /// Names the model in the in-use error the owner reads.
        var displayName: String
        /// Every file the local load needs is on disk (and from the pinned revision).
        var modelsPresent: @Sendable () -> Bool
        var bytesOnDisk: @Sendable () -> Int64
        /// Downloads every file and excludes the folder from backup. The only hook allowed to use the network.
        var download: @Sendable (_ progress: @escaping ProgressHandler) async throws -> Void
        /// Loads from local files only; must never download.
        var load: @Sendable () async throws -> Runtime
        var remove: @Sendable () throws -> Void
    }

    private struct Job<Value: Sendable> {
        let id: UUID
        let task: Task<Value, any Error>
    }

    private struct StaleLoad: Error {}

    private let hooks: Hooks
    private let tracker = ModelDownloadTracker()
    private var generation = 0
    private var downloadJob: Job<Void>?
    private var loadJob: Job<Runtime>?
    private var deletion: Task<Void, any Error>?
    private var loaded: ModelLease<Runtime>?
    private var leaseCount = 0

    init(hooks: Hooks) {
        self.hooks = hooks
    }

    static func inUseMessage(for displayName: String) -> String {
        "\(displayName) is in use by a running job. Delete it after the job finishes."
    }

    /// True when a runtime for the current generation is loaded.
    var isLoaded: Bool {
        loaded?.generation == generation
    }

    var isDeleting: Bool {
        deletion != nil
    }

    var activeLeaseCount: Int {
        leaseCount
    }

    // MARK: - Assets

    /// Never downloads; reads the file system and the in-flight download state.
    func status() -> ModelAssetStatus {
        if let fraction = tracker.inFlightFraction {
            return .downloading(fraction: fraction)
        }
        if deletion == nil, hooks.modelsPresent() {
            return .ready(bytesOnDisk: hooks.bytesOnDisk())
        }
        if let failure = tracker.lastFailure {
            return .failed(message: failure)
        }
        return .notDownloaded
    }

    /// Starts or joins the download. A joining caller sees only 0 and 1 as progress; `status()` has the live
    /// fraction. Cancelling any caller cancels the shared download.
    func download(progress: @escaping @Sendable (Double) -> Void) async throws {
        while let deletion {
            _ = await deletion.result
        }
        let job: Job<Void>
        if let downloadJob {
            job = downloadJob
        } else {
            let id = UUID()
            let hooks = hooks
            let tracker = tracker
            tracker.begin()
            let handler = tracker.progressHandler(forwardingTo: progress)
            let task = Task {
                defer { self.clearDownloadJob(id) }
                do {
                    try await hooks.download(handler)
                    tracker.finish(failure: nil)
                } catch {
                    tracker.finish(failure: SpeechEngineError.failureMessage(for: error))
                    throw error
                }
            }
            job = Job(id: id, task: task)
            downloadJob = job
        }
        progress(0)
        do {
            try await withTaskCancellationHandler {
                try await job.task.value
            } onCancel: {
                job.task.cancel()
            }
        } catch {
            throw SpeechEngineError.mapping(error)
        }
        progress(1)
    }

    /// Refuses while leased; otherwise invalidates the loaded runtime, cancels and awaits in-flight work, then
    /// removes the files. Concurrent deletes join.
    func delete() async throws {
        if let deletion {
            return try await Self.mapped { try await deletion.value }
        }
        guard leaseCount == 0 else {
            throw SpeechEngineError.underlying(Self.inUseMessage(for: hooks.displayName))
        }
        generation += 1
        loaded = nil
        let pendingDownload = downloadJob?.task
        let pendingLoad = loadJob?.task
        downloadJob = nil
        loadJob = nil
        pendingDownload?.cancel()
        pendingLoad?.cancel()
        let remove = hooks.remove
        let task = Task {
            defer { self.deletion = nil }
            // The download may be renaming `.partial` files and the load may be reading bundles: both must be
            // finished before anything is removed.
            _ = await pendingDownload?.result
            _ = await pendingLoad?.result
            try await Self.offActor(remove)
        }
        deletion = task
        try await Self.mapped { try await task.value }
    }

    // MARK: - Runtime

    /// Loads the runtime for the current generation from local files. Idempotent; concurrent callers share one
    /// load.
    func prepare() async throws {
        let startGeneration = generation
        if isLoaded { return }
        guard deletion == nil, downloadJob == nil, hooks.modelsPresent() else {
            throw SpeechEngineError.modelNotDownloaded(hooks.engineID)
        }
        let job: Job<Runtime>
        if let loadJob {
            job = loadJob
        } else {
            let id = UUID()
            let load = hooks.load
            let task = Task { () async throws -> Runtime in
                defer { self.clearLoadJob(id) }
                let runtime = try await load()
                // A delete ran while CoreML was compiling: the result belongs to deleted files. Discard it.
                guard self.generation == startGeneration, !Task.isCancelled else { throw StaleLoad() }
                self.loaded = ModelLease(runtime: runtime, generation: startGeneration)
                return runtime
            }
            job = Job(id: id, task: task)
            loadJob = job
        }
        do {
            _ = try await job.task.value
        } catch {
            if error is StaleLoad || generation != startGeneration {
                throw SpeechEngineError.modelNotDownloaded(hooks.engineID)
            }
            throw SpeechEngineError.mapping(error)
        }
    }

    /// `prepare()`, then checks out the runtime. While any lease is out, `delete()` refuses.
    func acquire() async throws -> ModelLease<Runtime> {
        try await prepare()
        // Re-check after the suspension: a delete may have run between the load finishing and this resumption.
        guard deletion == nil, let loaded, loaded.generation == generation else {
            throw SpeechEngineError.modelNotDownloaded(hooks.engineID)
        }
        leaseCount += 1
        return loaded
    }

    func release(_ lease: ModelLease<Runtime>) {
        leaseCount -= 1
    }

    // MARK: - Helpers

    private func clearDownloadJob(_ id: UUID) {
        if downloadJob?.id == id {
            downloadJob = nil
        }
    }

    private func clearLoadJob(_ id: UUID) {
        if loadJob?.id == id {
            loadJob = nil
        }
    }

    /// Runs synchronous file work on the generic executor instead of the actor.
    private static func offActor(_ body: @Sendable () throws -> Void) async throws {
        try body()
    }

    private static func mapped(_ body: () async throws -> Void) async throws {
        do {
            try await body()
        } catch {
            throw SpeechEngineError.mapping(error)
        }
    }
}
