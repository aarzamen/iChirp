import Foundation
import Synchronization
import XCTest

@testable import ChirpEngineWhisperKit

/// Review R3-4: `AsyncPermit` and `awaitSharedTask` are copied into ChirpEngineFluidAudio and ChirpEngineWhisperKit
/// (an engine target depends only on ChirpCore, ADR-004). This file's tests are the same in both test targets, so the
/// two copies keep one behavior; ChirpEngineFluidAudioTests' copy of this file also compares their code line by line.
final class ConcurrencyHelperParityTests: XCTestCase {
    // MARK: - AsyncPermit

    func testPermitsGoToWaitersInArrivalOrder() async throws {
        let permit = AsyncPermit(value: 1)
        try await permit.wait()
        let order = ParityLog<Int>()
        var waiters: [Task<Void, any Error>] = []
        for index in 0..<3 {
            waiters.append(
                Task {
                    try await permit.wait()
                    order.append(index)
                    permit.signal()
                })
            // Each waiter is in line before the next one starts: a signal, not a sleep (review R3-19).
            await waitForQueue(permit, count: index + 1)
        }
        permit.signal()
        for waiter in waiters { try await waiter.value }
        XCTAssertEqual(order.values, [0, 1, 2])
        XCTAssertEqual(permit.pendingWaiterCount(), 0)
    }

    func testACancelledWaiterLeavesTheLineAtOnceAndTheNextOneIsServed() async throws {
        let permit = AsyncPermit(value: 1)
        try await permit.wait()
        let cancelled = Task { try await permit.wait() }
        await waitForQueue(permit, count: 1)
        let next = Task { try await permit.wait() }
        await waitForQueue(permit, count: 2)

        cancelled.cancel()
        do {
            try await cancelled.value
            XCTFail("a cancelled waiter must throw")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertEqual(permit.pendingWaiterCount(), 1, "the cancelled waiter left the line while the permit was held")

        permit.signal()
        try await next.value
        XCTAssertEqual(permit.pendingWaiterCount(), 0)
        permit.signal()
    }

    func testAWaiterCancelledBeforeItWaitsNeverTakesAPermit() async throws {
        let permit = AsyncPermit(value: 0)
        let waiter = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await permit.wait()
        }
        do {
            try await waiter.value
            XCTFail("a cancelled waiter must throw")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        permit.signal()
        try await permit.wait()  // the permit is still free
        XCTAssertEqual(permit.pendingWaiterCount(), 0)
    }

    // MARK: - awaitSharedTask

    func testACancelledWaiterGivesUpAloneAndTheSharedTaskGoesOn() async throws {
        let latch = ParityLatch()
        let shared = Task<Int, any Error> {
            await latch.wait()
            return 42
        }
        let kept = Task { try await awaitSharedTask(shared) }
        let cancelled = Task { try await awaitSharedTask(shared) }
        cancelled.cancel()
        do {
            _ = try await cancelled.value
            XCTFail("a cancelled waiter must throw")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertFalse(shared.isCancelled, "the shared task goes on for everyone else")
        await latch.open()
        let value = try await kept.value
        XCTAssertEqual(value, 42)
    }

    func testASharedTaskFailureReachesEveryWaiter() async {
        struct Failure: Error, Equatable {}
        let shared = Task<Int, any Error> { throw Failure() }
        for _ in 0..<2 {
            do {
                _ = try await awaitSharedTask(shared)
                XCTFail("the failure must pass through")
            } catch {
                XCTAssertEqual(error as? Failure, Failure())
            }
        }
    }

    // MARK: - Helpers

    /// Polls until `count` callers wait in `permit`'s line (review R3-19: a signal instead of a sleep).
    private func waitForQueue(
        _ permit: AsyncPermit, count: Int, file: StaticString = #filePath, line: UInt = #line
    ) async {
        let deadline = ContinuousClock.now + .seconds(10)
        while permit.pendingWaiterCount() < count {
            guard ContinuousClock.now < deadline else {
                return XCTFail("\(count) waiters never queued", file: file, line: line)
            }
            await Task.yield()
        }
    }
}

/// A thread-safe append-only log.
private final class ParityLog<Element: Sendable>: Sendable {
    private let storage = Mutex<[Element]>([])

    func append(_ element: Element) { storage.withLock { $0.append(element) } }
    var values: [Element] { storage.withLock { $0 } }
}

/// A one-shot gate.
private actor ParityLatch {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}
