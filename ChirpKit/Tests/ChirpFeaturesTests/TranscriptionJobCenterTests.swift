import ChirpCore
import Foundation
import Observation
import XCTest

@testable import ChirpFeatures

@MainActor
final class TranscriptionJobCenterTests: XCTestCase {
    func testStartImportsAndProcessesThenClearsProgress() async throws {
        let center = TranscriptionJobCenter()
        let h = try PipelineHarness(testCase: self, onProgress: center.progressHandler)
        let source = try h.makeSourceFile()

        center.start(fileAt: source, pipeline: h.pipeline)
        await center.waitUntilIdle()

        let rows = try await h.store.fetchAll()
        XCTAssertEqual(rows.map(\.status), [.completed])
        XCTAssertTrue(center.progress.isEmpty, "a finished job leaves no progress entry: \(center.progress)")
        XCTAssertFalse(center.isRunning(rows[0].id))
        XCTAssertNil(center.lastImportError)
    }

    func testProgressIsPublishedWhileTheJobRuns() async throws {
        let center = TranscriptionJobCenter()
        let h = try PipelineHarness(testCase: self, onProgress: center.progressHandler)
        let hold = await h.speech.holdNextTranscription()

        center.start(fileAt: try h.makeSourceFile(), pipeline: h.pipeline)
        await hold.entered.wait()
        let fetchedId = try await h.store.fetchAll().first?.id
        let id = try XCTUnwrap(fetchedId)
        await waitUntil { center.progress[id]?.stage == .transcribing }

        XCTAssertTrue(center.isRunning(id))
        hold.release.fire()
        await center.waitUntilIdle()
        XCTAssertNil(center.progress[id])
    }

    func testCancelMarksRowCancelledAndClearsProgress() async throws {
        let center = TranscriptionJobCenter()
        let h = try PipelineHarness(testCase: self, onProgress: center.progressHandler)
        let hold = await h.speech.holdNextTranscription()

        center.start(fileAt: try h.makeSourceFile(), pipeline: h.pipeline)
        await hold.entered.wait()
        let fetchedId = try await h.store.fetchAll().first?.id
        let id = try XCTUnwrap(fetchedId)
        XCTAssertTrue(center.isRunning(id))
        center.cancel(id)
        await center.waitUntilIdle()

        let fetchedRow = await h.store.row(id)
        let row = try XCTUnwrap(fetchedRow)
        XCTAssertEqual(row.status, .cancelled)
        XCTAssertNil(center.progress[id])
        XCTAssertFalse(center.isRunning(id))
        XCTAssertTrue(fileExists(h.sourceURL(for: id)))
    }

    func testRetryRunsATrackedJob() async throws {
        let center = TranscriptionJobCenter()
        let h = try PipelineHarness(testCase: self, onProgress: center.progressHandler)
        await h.speech.failTranscription(with: FakeError(message: "engine hiccup"))
        center.start(fileAt: try h.makeSourceFile(), pipeline: h.pipeline)
        await center.waitUntilIdle()
        let fetchedId = try await h.store.fetchAll().first?.id
        let id = try XCTUnwrap(fetchedId)
        let failed = await h.store.row(id)
        XCTAssertEqual(failed?.status, .failed)

        await h.speech.failTranscription(with: nil)
        center.retry(id, pipeline: h.pipeline)
        XCTAssertTrue(center.isRunning(id))
        await center.waitUntilIdle()

        let row = await h.store.row(id)
        XCTAssertEqual(row?.status, .completed)
        XCTAssertNil(center.progress[id])
    }

    func testImportFailureIsSurfaced() async throws {
        let center = TranscriptionJobCenter()
        let h = try PipelineHarness(testCase: self, onProgress: center.progressHandler)

        center.start(fileAt: h.inbox.appendingPathComponent("missing.m4a"), pipeline: h.pipeline)
        await center.waitUntilIdle()

        XCTAssertNotNil(center.lastImportError)
        XCTAssertTrue(center.progress.isEmpty, "a failed import leaves no stuck progress entry: \(center.progress)")
        let rows = try await h.store.fetchAll()
        XCTAssertTrue(rows.isEmpty)
        XCTAssertTrue(h.recorder.events.isEmpty, "no progress is reported before the row exists")

        center.dismissImportError()
        XCTAssertNil(center.lastImportError)
    }

    func testProgressHandlerHopsToTheMainActor() async {
        let center = TranscriptionJobCenter()
        let id = UUID()
        let handler = center.progressHandler

        Task.detached { handler(id, JobProgress(stage: .normalizing, fraction: 0.1)) }
        await waitUntil { center.progress[id] != nil }

        XCTAssertEqual(center.progress[id], JobProgress(stage: .normalizing, fraction: 0.1))
    }

    func testUpdateAfterFinishIsIgnored() {
        let center = TranscriptionJobCenter()
        let id = UUID()

        center.update(id, JobProgress(stage: .transcribing, fraction: 0.5))
        XCTAssertEqual(center.progress[id], JobProgress(stage: .transcribing, fraction: 0.5))
        center.finish(id)
        center.update(id, JobProgress(stage: .finishing, fraction: 1))

        XCTAssertNil(center.progress[id], "a late progress hop must not resurrect a finished job")
    }
}
