import XCTest

@testable import ChirpCore

/// M2 Step 3 (moved to ChirpCore by M7): the tail-window preview with a fake transcriber. Ticks are driven by the test, never by time.
final class TailWindowPreviewSessionTests: XCTestCase {
    /// A transcriber that records each window and can hold a pass until the test releases it.
    private final class FakeTranscriber: @unchecked Sendable {
        // @unchecked Sendable: mutable state is only touched while `lock` is held.
        private let lock = NSLock()
        private var windows: [Int] = []
        private var cancelled = 0
        private var reply = "hello world"
        let hold: Latch?

        init(hold: Latch? = nil) {
            self.hold = hold
        }

        var windowSizes: [Int] { lock.withLock { windows } }
        var cancellations: Int { lock.withLock { cancelled } }
        func setReply(_ text: String) { lock.withLock { reply = text } }

        func transcribe(_ window: [Float]) async throws -> String {
            lock.withLock { windows.append(window.count) }
            if let hold { await hold.wait() }
            if Task.isCancelled {
                lock.withLock { cancelled += 1 }
                throw CancellationError()
            }
            return lock.withLock { reply }
        }
    }

    private func makeSession(
        _ fake: FakeTranscriber, scheduler: SpeechJobScheduler = SpeechJobScheduler()
    ) -> TailWindowPreviewSession {
        TailWindowPreviewSession(scheduler: scheduler) { window in try await fake.transcribe(window) }
    }

    private func seconds(_ value: Double) -> [Float] {
        [Float](repeating: 0.1, count: Int(value * 16_000))
    }

    func testEachTickTranscribesTheCurrentWindowAndPublishesTheText() async throws {
        let fake = FakeTranscriber()
        let session = makeSession(fake)
        var updates = session.updates.makeAsyncIterator()

        await session.append(seconds(1))
        await session.tick()
        let first = await updates.next()
        XCTAssertEqual(first, "hello world")

        fake.setReply("hello world again")
        await session.append(seconds(1))
        await session.tick()
        let second = await updates.next()
        XCTAssertEqual(second, "hello world again")
        XCTAssertEqual(fake.windowSizes, [16_000, 32_000])
        await session.finish()
    }

    func testWindowKeepsOnlyTheLastFifteenSeconds() async throws {
        let fake = FakeTranscriber()
        let session = makeSession(fake)
        var updates = session.updates.makeAsyncIterator()
        await session.append(seconds(20))
        await session.tick()
        _ = await updates.next()
        XCTAssertEqual(fake.windowSizes, [15 * 16_000])
        await session.finish()
    }

    func testTicksWhileAPassRunsAreSkippedNotQueued() async throws {
        let hold = Latch()
        let fake = FakeTranscriber(hold: hold)
        let session = makeSession(fake)
        var updates = session.updates.makeAsyncIterator()

        await session.append(seconds(1))
        await session.tick()
        await waitUntil { fake.windowSizes.count == 1 }
        // Three more ticks with new audio while the first pass is held: none may start a pass.
        for _ in 0..<3 {
            await session.append(seconds(0.5))
            await session.tick()
        }
        let skipped = await session.skippedTicks
        XCTAssertEqual(skipped, 3)
        XCTAssertEqual(fake.windowSizes.count, 1, "single-flight")

        await hold.open()
        _ = await updates.next()
        // The next tick after the pass ends runs once, on the newest window.
        await session.tick()
        _ = await updates.next()
        XCTAssertEqual(fake.windowSizes, [16_000, 40_000])
        let passes = await session.passCount
        XCTAssertEqual(passes, 2)
        await session.finish()
    }

    func testATickWithoutNewAudioOrUnderHalfASecondDoesNothing() async throws {
        let fake = FakeTranscriber()
        let session = makeSession(fake)
        var updates = session.updates.makeAsyncIterator()

        await session.append(seconds(0.25))
        await session.tick()
        await session.append(seconds(0.5))
        await session.tick()
        _ = await updates.next()
        await session.tick()  // nothing new since the last pass
        let passes = await session.passCount
        XCTAssertEqual(passes, 1)
        XCTAssertEqual(fake.windowSizes, [12_000])
        await session.finish()
    }

    func testFinishCancelsAndDrainsThePassInFlightAndEndsUpdates() async throws {
        let hold = Latch()
        let fake = FakeTranscriber(hold: hold)
        let session = makeSession(fake)

        await session.append(seconds(2))
        await session.tick()
        await waitUntil { fake.windowSizes.count == 1 }

        let finishing = Task { await session.finish() }
        await waitUntil { await session.isFinishing }
        // The held pass ignores cancellation until released, like a CoreML call; finish must wait for it.
        await hold.open()
        await finishing.value
        XCTAssertEqual(fake.cancellations, 1, "the pass in flight was cancelled")

        var texts: [String] = []
        for await text in session.updates { texts.append(text) }
        XCTAssertEqual(texts, [], "a cancelled pass publishes nothing and the stream ends")

        await session.append(seconds(1))
        await session.tick()
        let passes = await session.passCount
        XCTAssertEqual(passes, 1, "nothing runs after finish")
    }

    func testPassesUseTheInteractiveSlotSoABackgroundJobNeverBlocksThem() async throws {
        let scheduler = SpeechJobScheduler()
        let background = Latch()
        let fileJob = Task {
            try await scheduler.run(.fileTranscription) { await background.wait() }
        }
        let fake = FakeTranscriber()
        let session = makeSession(fake, scheduler: scheduler)
        var updates = session.updates.makeAsyncIterator()

        await session.append(seconds(1))
        await session.tick()
        let text = await updates.next()
        XCTAssertEqual(text, "hello world", "the preview ran while the background slot was busy")

        await background.open()
        try await fileJob.value
        await session.finish()
    }

    func testAFailedPassIsSkippedAndTheNextOneStillRuns() async throws {
        struct Boom: Error {}
        let calls = LockedLog<Int>()
        let session = TailWindowPreviewSession(scheduler: SpeechJobScheduler()) { window in
            calls.append(window.count)
            if calls.values.count == 1 { throw Boom() }
            return "recovered"
        }
        var updates = session.updates.makeAsyncIterator()
        await session.append(seconds(1))
        await session.tick()
        await waitUntil { calls.values.count == 1 }
        await waitUntil { await session.passCount == 1 }
        // Let the failed pass clear before the next tick.
        await waitUntil { await session.isIdle }
        await session.append(seconds(1))
        await session.tick()
        let text = await updates.next()
        XCTAssertEqual(text, "recovered")
        await session.finish()
    }
}
