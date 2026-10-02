import Dispatch
import XCTest

@testable import ChirpCore

/// The one bridge for blocking work (plan 024 fix round 1): it runs on the caller's dispatch queue, never on Swift's
/// cooperative pool, hands back the result or the error, and lets the work see the awaiting task's cancellation.
final class BlockingQueueWorkTests: XCTestCase {
    private static let label = "com.aarzamen.ichirp.tests.blocking-queue-work"
    private let queue = DispatchQueue(label: BlockingQueueWorkTests.label, attributes: .concurrent)

    func testWorkRunsOnTheGivenQueue() async throws {
        let label = try await BlockingQueueWork.run(on: queue) { _ in
            String(cString: __dispatch_queue_get_label(nil))
        }
        XCTAssertEqual(label, Self.label)
    }

    func testResultsAndErrorsPassThrough() async {
        struct Refused: Error, Equatable {}
        let value = try? await BlockingQueueWork.run(on: queue) { isCancelled in isCancelled() ? -1 : 42 }
        XCTAssertEqual(value, 42, "not cancelled: the check reads false")
        do {
            _ = try await BlockingQueueWork.run(on: queue) { _ -> Int in throw Refused() }
            XCTFail("expected the work's error")
        } catch {
            XCTAssertEqual(error as? Refused, Refused())
        }
    }

    /// Deterministic: the work waits until the test has cancelled the task, then reads the check once.
    func testWorkSeesTheAwaitingTasksCancellation() async throws {
        let cancelled = DispatchSemaphore(value: 0)
        let task = Task { [queue] in
            try await BlockingQueueWork.run(on: queue) { isCancelled in
                cancelled.wait()
                return isCancelled()
            }
        }
        task.cancel()
        cancelled.signal()
        let sawCancellation = try await task.value
        XCTAssertTrue(sawCancellation)
    }
}
