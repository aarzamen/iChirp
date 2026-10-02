import Foundation
import Synchronization

/// Runs blocking document work (file reads, unzipping, XML and HTML parsing, RTF import, PDF text and page rendering)
/// on a dedicated dispatch queue, never on Swift's cooperative thread pool or the caller's actor.
///
/// The pool has about one thread per CPU core; a few long parses there would stall every other async task in the app
/// (store reads, scheduler hops, view models awaiting results). Same pattern as `AVAudioNormalizer.runOnDecodeQueue`.
enum BlockingWork {
    static let queueLabel = "com.aarzamen.ichirp.ingest.documents"
    /// Concurrent, so each import gets its own dispatch thread; blocking a dispatch thread does not starve Swift
    /// concurrency. The person waits on this work, hence `userInitiated`.
    private static let queue = DispatchQueue(label: queueLabel, qos: .userInitiated, attributes: .concurrent)

    /// Runs `work` on the document queue and returns its result. `work` receives a check that turns true once the
    /// awaiting task is cancelled (dispatch threads have no current task, so `Task.isCancelled` would stay false);
    /// it should throw `CancellationError` between its parts when it does.
    static func run<T: Sendable>(
        _ work: @escaping @Sendable (_ isCancelled: @escaping @Sendable () -> Bool) throws -> T
    ) async throws -> T {
        let cancelled = CancellationFlag()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    continuation.resume(with: Result { try work { cancelled.isSet } })
                }
            }
        } onCancel: {
            cancelled.set()
        }
    }

    /// Throws `CancellationError` when `isCancelled` says so: the check between a reader's parts.
    static func checkCancellation(_ isCancelled: () -> Bool) throws {
        if isCancelled() { throw CancellationError() }
    }
}

/// A one-way flag set from a task's cancellation handler and read from a dispatch thread.
private final class CancellationFlag: Sendable {
    private let state = Mutex(false)

    var isSet: Bool { state.withLock { $0 } }

    func set() {
        state.withLock { $0 = true }
    }
}
