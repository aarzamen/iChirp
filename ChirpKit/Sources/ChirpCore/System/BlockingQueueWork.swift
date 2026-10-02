import Dispatch
import Foundation
import Synchronization

/// The one bridge for blocking work (decoding and encoding audio, reading and parsing documents): it runs the work on
/// a dispatch queue the caller owns, never on Swift's cooperative thread pool or the caller's actor, and resumes the
/// caller with its result.
///
/// The pool has about one thread per CPU core; a few long blocking jobs there would stall every other async task in
/// the app. A dispatch thread has no current task, so `Task.isCancelled` stays false there: the work instead receives
/// `isCancelled`, which turns true once the awaiting task is cancelled, and checks it between its parts.
public enum BlockingQueueWork {
    /// Runs `work` on `queue` and returns its result (or rethrows its error).
    public static func run<T: Sendable>(
        on queue: DispatchQueue,
        _ work: @escaping @Sendable (_ isCancelled: @escaping @Sendable () -> Bool) throws -> T
    ) async throws -> T {
        let cancelled = BlockingWorkCancellation()
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
}

/// A one-way flag set from a task's cancellation handler and read from a dispatch thread.
final class BlockingWorkCancellation: Sendable {
    private let state = Mutex(false)

    var isSet: Bool { state.withLock { $0 } }

    func set() {
        state.withLock { $0 = true }
    }
}
