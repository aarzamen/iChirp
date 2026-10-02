import ChirpCore
import Foundation

/// Runs blocking document work (file reads, unzipping, XML and HTML parsing, RTF import, PDF text and page rendering)
/// on the ingest document queue, never on Swift's cooperative thread pool or the caller's actor, through ChirpCore's
/// `BlockingQueueWork` (the pool has about one thread per CPU core; a few long parses there would stall every other
/// async task in the app).
enum BlockingWork {
    static let queueLabel = "com.aarzamen.ichirp.ingest.documents"
    /// Concurrent, so each import gets its own dispatch thread; blocking a dispatch thread does not starve Swift
    /// concurrency. The person waits on this work, hence `userInitiated`.
    private static let queue = DispatchQueue(label: queueLabel, qos: .userInitiated, attributes: .concurrent)

    /// Runs `work` on the document queue and returns its result. `work` receives a check that turns true once the
    /// awaiting task is cancelled; it should throw `CancellationError` between its parts when it does.
    static func run<T: Sendable>(
        _ work: @escaping @Sendable (_ isCancelled: @escaping @Sendable () -> Bool) throws -> T
    ) async throws -> T {
        try await BlockingQueueWork.run(on: queue, work)
    }

    /// Throws `CancellationError` when `isCancelled` says so: the check between a reader's parts.
    static func checkCancellation(_ isCancelled: () -> Bool) throws {
        if isCancelled() { throw CancellationError() }
    }
}
