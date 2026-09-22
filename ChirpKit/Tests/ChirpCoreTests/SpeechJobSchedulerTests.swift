import XCTest
@testable import ChirpCore

final class SpeechJobSchedulerTests: XCTestCase {
    actor Log { var items: [String] = []; func add(_ s: String) { items.append(s) } }

    func testBackgroundJobsRunByPriorityThenFIFO() async throws {
        let scheduler = SpeechJobScheduler()
        let log = Log()
        let gate = AsyncStream<Void>.makeStream()
        // Occupy the background slot so the next three queue up.
        let blocker = Task { try await scheduler.run(.fileTranscription) { for await _ in gate.stream { break }; await log.add("blocker") } }
        try await Task.sleep(for: .milliseconds(50))
        let f2 = Task { try await scheduler.run(.fileTranscription) { await log.add("file2") } }
        try await Task.sleep(for: .milliseconds(20))
        let live = Task { try await scheduler.run(.meetingLiveChunk) { await log.add("live") } }
        try await Task.sleep(for: .milliseconds(20))
        let fin = Task { try await scheduler.run(.meetingFinalize) { await log.add("finalize") } }
        try await Task.sleep(for: .milliseconds(20))
        gate.continuation.yield(())
        _ = try await (blocker.value, f2.value, live.value, fin.value)
        let order = await log.items
        XCTAssertEqual(order, ["blocker", "finalize", "live", "file2"])
    }

    func testDictationUsesInteractiveSlotAndIsNotBlockedByBackground() async throws {
        let scheduler = SpeechJobScheduler()
        let gate = AsyncStream<Void>.makeStream()
        let background = Task { try await scheduler.run(.fileTranscription) { for await _ in gate.stream { break } } }
        try await Task.sleep(for: .milliseconds(50))
        let result = try await scheduler.run(.dictation) { "dictated" }
        XCTAssertEqual(result, "dictated")
        gate.continuation.yield(()); _ = try await background.value
    }

    func testCancellingPendingJobRemovesIt() async throws {
        let scheduler = SpeechJobScheduler()
        let gate = AsyncStream<Void>.makeStream()
        let blocker = Task { try await scheduler.run(.fileTranscription) { for await _ in gate.stream { break } } }
        try await Task.sleep(for: .milliseconds(50))
        let pending = Task { try await scheduler.run(.fileTranscription) { XCTFail("must not run") } }
        try await Task.sleep(for: .milliseconds(20))
        pending.cancel()
        do { _ = try await pending.value; XCTFail("expected cancellation") } catch is CancellationError {}
        let count = await scheduler.pendingCount()
        XCTAssertEqual(count, 0)
        gate.continuation.yield(()); _ = try await blocker.value
    }

    func testLiveChunkBackpressureDropsOldest() async throws {
        let scheduler = SpeechJobScheduler(maxPendingLiveChunks: 1)
        let gate = AsyncStream<Void>.makeStream()
        let blocker = Task { try await scheduler.run(.fileTranscription) { for await _ in gate.stream { break } } }
        try await Task.sleep(for: .milliseconds(50))
        let first = Task { try await scheduler.run(.meetingLiveChunk) { "first" } }
        try await Task.sleep(for: .milliseconds(20))
        let second = Task { try await scheduler.run(.meetingLiveChunk) { "second" } }
        try await Task.sleep(for: .milliseconds(20))
        gate.continuation.yield(())
        do { _ = try await first.value; XCTFail("oldest must be dropped") } catch let e as SpeechJobError { XCTAssertEqual(e, .droppedDueToBackpressure) }
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
}
