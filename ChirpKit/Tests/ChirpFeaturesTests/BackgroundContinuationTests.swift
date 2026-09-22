import ChirpCore
import Foundation
import XCTest

@testable import ChirpFeatures

/// M1.5 Step 2: a user-started job keeps running in the background under one continued-processing request per user
/// action. Progress is the jobs' real progress (monotonic 0…1), the task completes when the jobs end, and expiration
/// (Cancel in the Live Activity) cancels the jobs: rows end `cancelled`, never lost.
@MainActor
final class BackgroundContinuationTests: XCTestCase {
    // MARK: - With the job center and the fake pipeline

    func testJobProgressMapsToMonotonicSystemProgressAndCompletesWithSuccess() async throws {
        let scheduler = FakeContinuedProcessingScheduler()
        let center = TranscriptionJobCenter(continuedProcessing: scheduler)
        let h = try PipelineHarness(testCase: self, onProgress: center.progressHandler)
        let hold = await h.speech.holdNextTranscription()

        center.start(filesAt: [try h.makeSourceFile(named: "Ward round.m4a")], pipeline: h.pipeline)
        XCTAssertEqual(scheduler.submissions.count, 1, "one request per user action, submitted at once")
        let submission = try XCTUnwrap(scheduler.submissions.first)
        XCTAssertEqual(submission.kind, .transcription)
        XCTAssertEqual(submission.title, "Ward round", "titled after the file")
        let task = try XCTUnwrap(scheduler.start(submission.id))
        XCTAssertEqual(task.progress.totalUnitCount, BackgroundContinuation.totalUnits)

        await hold.entered.wait()
        let fetchedId = try await h.store.fetchAll().first?.id
        let id = try XCTUnwrap(fetchedId)
        await waitUntil { center.progress[id]?.stage == .transcribing }
        XCTAssertGreaterThan(task.progress.completedUnitCount, 0, "real progress reached the system task")
        XCTAssertTrue(task.subtitles.contains { $0.hasPrefix("Transcribing · ") }, "\(task.subtitles)")
        XCTAssertTrue(task.completions.isEmpty, "not completed while the job runs")

        hold.release.fire()
        await center.waitUntilIdle()

        let row = await h.store.row(id)
        XCTAssertEqual(row?.status, .completed)
        XCTAssertEqual(task.completions, [true])
        let units = task.reportedUnits
        XCTAssertEqual(units, units.sorted(), "system progress never goes backwards: \(units)")
        XCTAssertEqual(units.last, BackgroundContinuation.totalUnits)
        XCTAssertTrue(units.allSatisfy { (0...BackgroundContinuation.totalUnits).contains($0) })
        XCTAssertTrue(scheduler.withdrawn.isEmpty)
    }

    func testExpirationCancelsTheJobAndCompletesUnsuccessfully() async throws {
        let scheduler = FakeContinuedProcessingScheduler()
        let center = TranscriptionJobCenter(continuedProcessing: scheduler)
        let h = try PipelineHarness(testCase: self, onProgress: center.progressHandler)
        let hold = await h.speech.holdNextTranscription()

        center.start(filesAt: [try h.makeSourceFile()], pipeline: h.pipeline)
        let task = try XCTUnwrap(scheduler.startLast())
        await hold.entered.wait()
        let fetchedId = try await h.store.fetchAll().first?.id
        let id = try XCTUnwrap(fetchedId)

        task.expire()
        await center.waitUntilIdle()

        let fetchedRow = await h.store.row(id)
        let row = try XCTUnwrap(fetchedRow, "the row is never lost")
        XCTAssertEqual(row.status, .cancelled)
        XCTAssertTrue(fileExists(h.sourceURL(for: id)), "the source is kept for Retry")
        XCTAssertEqual(task.completions, [false])
        XCTAssertFalse(center.isRunning(id))
    }

    func testABatchGetsOneRequestWithAggregateProgress() async throws {
        let scheduler = FakeContinuedProcessingScheduler()
        let center = TranscriptionJobCenter(continuedProcessing: scheduler)
        let h = try PipelineHarness(testCase: self, onProgress: center.progressHandler)
        let urls = [try h.makeSourceFile(named: "one.m4a"), try h.makeSourceFile(named: "two.m4a")]

        center.start(filesAt: urls, pipeline: h.pipeline)
        XCTAssertEqual(scheduler.submissions.map(\.title), ["2 files"])
        let task = try XCTUnwrap(scheduler.startLast())
        await center.waitUntilIdle()

        let rows = try await h.store.fetchAll()
        XCTAssertEqual(rows.map(\.status), [.completed, .completed])
        XCTAssertEqual(task.completions, [true])
        XCTAssertEqual(task.subtitles.last, "2 of 2 done · 100%")
        let units = task.reportedUnits
        XCTAssertEqual(units, units.sorted(), "\(units)")
    }

    func testAFailedJobCompletesTheTaskUnsuccessfully() async throws {
        let scheduler = FakeContinuedProcessingScheduler()
        let center = TranscriptionJobCenter(continuedProcessing: scheduler)
        let h = try PipelineHarness(testCase: self, onProgress: center.progressHandler)
        await h.speech.failTranscription(with: FakeError(message: "engine hiccup"))

        center.start(filesAt: [try h.makeSourceFile()], pipeline: h.pipeline)
        let task = try XCTUnwrap(scheduler.startLast())
        await center.waitUntilIdle()

        let rows = try await h.store.fetchAll()
        XCTAssertEqual(rows.map(\.status), [.failed])
        XCTAssertEqual(task.completions, [false])
    }

    func testARefusedRequestStillRunsTheJobInTheForeground() async throws {
        let scheduler = FakeContinuedProcessingScheduler()
        scheduler.refuses = true
        let center = TranscriptionJobCenter(continuedProcessing: scheduler)
        let h = try PipelineHarness(testCase: self, onProgress: center.progressHandler)

        center.start(filesAt: [try h.makeSourceFile()], pipeline: h.pipeline)
        await center.waitUntilIdle()

        let rows = try await h.store.fetchAll()
        XCTAssertEqual(rows.map(\.status), [.completed])
        XCTAssertTrue(scheduler.tasks.isEmpty)
    }

    func testAQueuedRequestIsWithdrawnWhenTheJobEndsFirst() async throws {
        let scheduler = FakeContinuedProcessingScheduler()
        let center = TranscriptionJobCenter(continuedProcessing: scheduler)
        let h = try PipelineHarness(testCase: self, onProgress: center.progressHandler)

        center.start(filesAt: [try h.makeSourceFile()], pipeline: h.pipeline)
        await center.waitUntilIdle()

        let submission = try XCTUnwrap(scheduler.submissions.first)
        XCTAssertEqual(scheduler.withdrawn, [submission.id], "a task the system never started is withdrawn")
        XCTAssertNil(scheduler.start(submission.id))
    }

    func testAFailedImportEndsItsItem() async throws {
        let scheduler = FakeContinuedProcessingScheduler()
        let center = TranscriptionJobCenter(continuedProcessing: scheduler)
        let h = try PipelineHarness(testCase: self, onProgress: center.progressHandler)

        center.start(filesAt: [h.inbox.appendingPathComponent("gone.m4a")], pipeline: h.pipeline)
        let task = try XCTUnwrap(scheduler.startLast())
        await center.waitUntilIdle()

        XCTAssertEqual(task.completions, [false])
        XCTAssertNotNil(center.lastImportError)
    }

    func testRetrySubmitsItsOwnRequest() async throws {
        let scheduler = FakeContinuedProcessingScheduler()
        let center = TranscriptionJobCenter(continuedProcessing: scheduler)
        let h = try PipelineHarness(testCase: self, onProgress: center.progressHandler)
        await h.speech.failTranscription(with: FakeError(message: "engine hiccup"))
        center.start(filesAt: [try h.makeSourceFile()], pipeline: h.pipeline)
        await center.waitUntilIdle()
        let fetchedId = try await h.store.fetchAll().first?.id
        let id = try XCTUnwrap(fetchedId)

        await h.speech.failTranscription(with: nil)
        center.retry(id, title: "Interview", pipeline: h.pipeline)
        XCTAssertEqual(scheduler.submissions.map(\.title), ["Interview", "Interview"])
        let task = try XCTUnwrap(scheduler.startLast())
        await center.waitUntilIdle()

        let row = await h.store.row(id)
        XCTAssertEqual(row?.status, .completed)
        XCTAssertEqual(task.completions, [true])
        XCTAssertNotEqual(scheduler.submissions[0].id, scheduler.submissions[1].id, "identifiers are never reused")
    }

    func testWithoutASchedulerNothingIsSubmitted() async throws {
        let center = TranscriptionJobCenter()
        let h = try PipelineHarness(testCase: self, onProgress: center.progressHandler)
        center.start(filesAt: [try h.makeSourceFile()], pipeline: h.pipeline)
        await center.waitUntilIdle()
        let rows = try await h.store.fetchAll()
        XCTAssertEqual(rows.map(\.status), [.completed])
    }

    // MARK: - The continuation on its own

    func testLowerFractionsAreIgnoredAndSubtitleNamesTheStage() throws {
        let scheduler = FakeContinuedProcessingScheduler()
        let item = UUID()
        let continuation = BackgroundContinuation(
            scheduler: scheduler, kind: .modelDownload, title: "Speech model", subtitle: "Downloading", items: [item])
        XCTAssertTrue(continuation.begin())
        let task = try XCTUnwrap(scheduler.startLast())
        XCTAssertEqual(task.titles.last, "Speech model")
        XCTAssertEqual(task.subtitles.last, "Downloading")

        continuation.update(item, fraction: 0.4, stage: "Downloading")
        continuation.update(item, fraction: 0.2, stage: "Downloading")
        continuation.update(item, fraction: 1.7, stage: "Downloading")

        XCTAssertEqual(task.reportedUnits.filter { $0 > 0 }, [400, 1_000], "0.2 after 0.4 is ignored; 1.7 clamps to 1")
        XCTAssertEqual(task.subtitles.last, "Downloading · 100%")
        XCTAssertEqual(continuation.reportedFraction, 1)
        continuation.end(item, succeeded: true)
        XCTAssertEqual(task.completions, [true])
        continuation.end(item, succeeded: false)
        XCTAssertEqual(task.completions, [true], "completed exactly once")
    }

    func testATaskStartedAfterTheWorkEndedCompletesAtOnce() throws {
        let scheduler = FakeContinuedProcessingScheduler()
        let item = UUID()
        let continuation = BackgroundContinuation(
            scheduler: scheduler, kind: .transcription, title: "Memo", subtitle: "Waiting to start", items: [item])
        continuation.begin()
        continuation.end(item, succeeded: true)
        XCTAssertTrue(continuation.isFinished)

        // The system starts a request it had queued before it saw the withdrawal.
        let task = FakeContinuedTask(requestID: "late")
        continuation.attach(task)

        XCTAssertEqual(task.completions, [true])
        XCTAssertEqual(task.progress.completedUnitCount, BackgroundContinuation.totalUnits)
    }

    func testExpirationWithoutAnEndCompletesAfterTheGrace() async throws {
        let scheduler = FakeContinuedProcessingScheduler()
        let item = UUID()
        let continuation = BackgroundContinuation(
            scheduler: scheduler, kind: .transcription, title: "Memo", subtitle: "Waiting to start", items: [item],
            expirationGrace: .milliseconds(20))
        var expirations = 0
        continuation.onExpiration = { expirations += 1 }
        continuation.begin()
        let task = try XCTUnwrap(scheduler.startLast())

        task.expire()
        task.expire()
        XCTAssertEqual(expirations, 1)
        XCTAssertTrue(task.completions.isEmpty, "waits for the cancelled work first")

        let deadline = ContinuousClock.now + .seconds(5)
        while task.completions.isEmpty, ContinuousClock.now < deadline {
            await Task.yield()
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(task.completions, [false])
        XCTAssertTrue(continuation.isFinished)
    }

    func testNoItemsOrNoSchedulerSubmitsNothing() {
        XCTAssertFalse(
            BackgroundContinuation(
                scheduler: nil, kind: .transcription, title: "t", subtitle: "s", items: [UUID()]
            ).begin())
        let scheduler = FakeContinuedProcessingScheduler()
        XCTAssertFalse(
            BackgroundContinuation(
                scheduler: scheduler, kind: .transcription, title: "t", subtitle: "s", items: []
            ).begin())
        XCTAssertTrue(scheduler.submissions.isEmpty)
    }

    func testTitleForFiles() {
        XCTAssertEqual(TranscriptionJobCenter.title(for: [URL(fileURLWithPath: "/tmp/Ward round.m4a")]), "Ward round")
        XCTAssertEqual(
            TranscriptionJobCenter.title(for: [URL(fileURLWithPath: "/a.m4a"), URL(fileURLWithPath: "/b.mov")]),
            "2 files")
    }
}
