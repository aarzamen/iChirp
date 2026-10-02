import XCTest
@testable import ChirpCore

final class SpeechJobSchedulerTests: XCTestCase {
    actor Log { var items: [String] = []; func add(_ s: String) { items.append(s) } }

    // The four tests below order their jobs with signals, never fixed sleeps (review R1-11, R8-12): the blocking job
    // says it holds the slot, and each queued job is counted in `pendingCount()` before the next one starts.

    /// Starts a job that holds `kind`'s slot until `gate` opens; returns once the job is running.
    private func occupySlot(
        _ scheduler: SpeechJobScheduler, _ kind: SpeechJobKind, until gate: AsyncStream<Void>, log: Log? = nil
    ) async -> Task<Void, any Error> {
        let started = AsyncStream<Void>.makeStream()
        let blocker = Task {
            try await scheduler.run(kind) {
                started.continuation.yield(())
                for await _ in gate { break }
                await log?.add("blocker")
            }
        }
        for await _ in started.stream { break }
        return blocker
    }

    /// Returns once `count` jobs wait in the scheduler's queue.
    private func waitForPending(_ scheduler: SpeechJobScheduler, _ count: Int) async {
        await waitUntil { await scheduler.pendingCount() == count }
    }

    func testBackgroundJobsRunByPriorityThenFIFO() async throws {
        let scheduler = SpeechJobScheduler()
        let log = Log()
        let gate = AsyncStream<Void>.makeStream()
        // Occupy the background slot so the next three queue up, in this order.
        let blocker = await occupySlot(scheduler, .fileTranscription, until: gate.stream, log: log)
        let f2 = Task { try await scheduler.run(.fileTranscription) { await log.add("file2") } }
        await waitForPending(scheduler, 1)
        let live = Task { try await scheduler.run(.meetingLiveChunk) { await log.add("live") } }
        await waitForPending(scheduler, 2)
        let fin = Task { try await scheduler.run(.meetingFinalize) { await log.add("finalize") } }
        await waitForPending(scheduler, 3)
        gate.continuation.yield(())
        _ = try await (blocker.value, f2.value, live.value, fin.value)
        let order = await log.items
        XCTAssertEqual(order, ["blocker", "finalize", "live", "file2"])
    }

    func testDictationUsesInteractiveSlotAndIsNotBlockedByBackground() async throws {
        let scheduler = SpeechJobScheduler()
        let gate = AsyncStream<Void>.makeStream()
        let background = await occupySlot(scheduler, .fileTranscription, until: gate.stream)
        let result = try await scheduler.run(.dictation) { "dictated" }
        XCTAssertEqual(result, "dictated")
        gate.continuation.yield(())
        _ = try await background.value
    }

    func testCancellingPendingJobRemovesIt() async throws {
        let scheduler = SpeechJobScheduler()
        let gate = AsyncStream<Void>.makeStream()
        let blocker = await occupySlot(scheduler, .fileTranscription, until: gate.stream)
        let pending = Task { try await scheduler.run(.fileTranscription) { XCTFail("must not run") } }
        await waitForPending(scheduler, 1)
        pending.cancel()
        do {
            _ = try await pending.value
            XCTFail("expected cancellation")
        } catch is CancellationError {}
        let count = await scheduler.pendingCount()
        XCTAssertEqual(count, 0)
        gate.continuation.yield(())
        _ = try await blocker.value
    }

    func testLiveChunkBackpressureDropsOldest() async throws {
        let scheduler = SpeechJobScheduler(maxPendingLiveChunks: 1)
        let gate = AsyncStream<Void>.makeStream()
        let blocker = await occupySlot(scheduler, .fileTranscription, until: gate.stream)
        let first = Task { try await scheduler.run(.meetingLiveChunk) { "first" } }
        await waitForPending(scheduler, 1)
        let second = Task { try await scheduler.run(.meetingLiveChunk) { "second" } }
        // Queuing the second chunk drops the first, which ends it at once; the slot is still held.
        do {
            _ = try await first.value
            XCTFail("oldest must be dropped")
        } catch let error as SpeechJobError {
            XCTAssertEqual(error, .droppedDueToBackpressure)
        }
        let pending = await scheduler.pendingCount()
        XCTAssertEqual(pending, 1, "only the newest chunk waits")
        gate.continuation.yield(())
        let s = try await second.value
        XCTAssertEqual(s, "second")
        _ = try await blocker.value
    }

    // MARK: - Additional coverage beyond the brief (deterministic: explicit start signals, no sleeps)

    struct Boom: Error {}

    func testCancellingRunningJobCancelsOperationAndReleasesSlot() async throws {
        let scheduler = SpeechJobScheduler()
        let started = AsyncStream<Void>.makeStream()
        let running = Task {
            try await scheduler.run(.fileTranscription) {
                started.continuation.yield(())
                // Throws CancellationError only if the scheduler forwards the caller's cancellation.
                try await Task.sleep(for: .seconds(60))
            }
        }
        for await _ in started.stream { break }
        running.cancel()
        do { _ = try await running.value; XCTFail("expected cancellation") } catch is CancellationError {}
        // Hangs here if the cancelled job never released the background slot.
        let next = try await scheduler.run(.fileTranscription) { "next" }
        XCTAssertEqual(next, "next")
    }

    func testThrowingOperationPropagatesErrorAndReleasesSlot() async throws {
        let scheduler = SpeechJobScheduler()
        do {
            _ = try await scheduler.run(.meetingFinalize) { () async throws -> Int in throw Boom() }
            XCTFail("expected the operation's error")
        } catch is Boom {}
        let value = try await scheduler.run(.meetingFinalize) { 42 }
        XCTAssertEqual(value, 42)
        let dictation = try await scheduler.run(.dictation) { () async throws -> Int in 7 }
        XCTAssertEqual(dictation, 7)
    }

    func testAlreadyCancelledCallerNeverRunsOperation() async throws {
        let scheduler = SpeechJobScheduler()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await scheduler.run(.dictation) { XCTFail("must not run") }
        }
        do { _ = try await task.value; XCTFail("expected cancellation") } catch is CancellationError {}
        let count = await scheduler.pendingCount()
        XCTAssertEqual(count, 0)
    }

    func testJobKindSlotsAndPriorityRanks() {
        XCTAssertEqual(SpeechJobKind.dictation.priorityRank, 0)
        XCTAssertEqual(SpeechJobKind.meetingFinalize.priorityRank, 0)
        XCTAssertEqual(SpeechJobKind.meetingLiveChunk.priorityRank, 1)
        XCTAssertEqual(SpeechJobKind.fileTranscription.priorityRank, 2)
        XCTAssertEqual(SpeechJobKind.allCases.filter(\.usesInteractiveSlot), [.dictation])
    }

    // MARK: - M2 carried item: a cancel racing a slot grant

    /// Releases a held job and cancels the next one in both orders, many times. Whatever wins, the waiting job either
    /// throws `CancellationError` without running or runs exactly once, and the slot is never leaked: a later job
    /// always gets it and nothing stays pending.
    func testCancelRacingASlotGrantNeverLeaksTheSlot() async throws {
        let scheduler = SpeechJobScheduler()
        for iteration in 0..<200 {
            let release = AsyncStream<Void>.makeStream()
            let holderStarted = AsyncStream<Void>.makeStream()
            let holder = Task {
                try await scheduler.run(.dictation) {
                    holderStarted.continuation.yield()
                    for await _ in release.stream { break }
                }
            }
            for await _ in holderStarted.stream { break }
            let ran = Log()
            let waiter = Task { try await scheduler.run(.dictation) { await ran.add("ran") } }
            while await scheduler.pendingCount() == 0 { await Task.yield() }

            if iteration.isMultiple(of: 2) {
                waiter.cancel()
                release.continuation.yield()
            } else {
                release.continuation.yield()
                waiter.cancel()
            }
            try await holder.value
            let outcome = await waiter.result
            let runs = await ran.items.count
            switch outcome {
            case .success:
                XCTAssertEqual(runs, 1, "iteration \(iteration)")
            case .failure(let error):
                XCTAssertTrue(error is CancellationError, "iteration \(iteration): \(error)")
                XCTAssertEqual(runs, 0, "a cancelled waiter never runs, iteration \(iteration)")
            }
            let next = try await scheduler.run(.dictation) { "free" }
            XCTAssertEqual(next, "free")
            let pending = await scheduler.pendingCount()
            XCTAssertEqual(pending, 0)
        }
    }

    /// A job cancelled after it was granted the slot but before its task resumed gives the slot back without running.
    func testGrantedButAlreadyCancelledJobReleasesTheSlotForTheNextWaiter() async throws {
        let scheduler = SpeechJobScheduler()
        let release = AsyncStream<Void>.makeStream()
        let holderStarted = AsyncStream<Void>.makeStream()
        let holder = Task {
            try await scheduler.run(.fileTranscription) {
                holderStarted.continuation.yield()
                for await _ in release.stream { break }
            }
        }
        for await _ in holderStarted.stream { break }
        let ran = Log()
        let cancelled = Task { try await scheduler.run(.fileTranscription) { await ran.add("cancelled-job") } }
        while await scheduler.pendingCount() < 1 { await Task.yield() }
        let third = Task { try await scheduler.run(.fileTranscription) { await ran.add("third") } }
        while await scheduler.pendingCount() < 2 { await Task.yield() }

        cancelled.cancel()
        release.continuation.yield()
        try await holder.value
        _ = await cancelled.result
        try await third.value
        let items = await ran.items
        XCTAssertTrue(items.contains("third"), "the next waiter got the slot")
        XCTAssertLessThanOrEqual(items.filter { $0 == "cancelled-job" }.count, 1)
    }
}
