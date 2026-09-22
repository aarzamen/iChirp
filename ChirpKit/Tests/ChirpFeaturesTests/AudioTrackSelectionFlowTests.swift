import ChirpCore
import Foundation
import XCTest

@testable import ChirpFeatures

/// M1.5 Step 4, the app flow (`spec/contracts/file-transcription-audio-tracks-v1.md`): a single-track file imports
/// at once; two or more tracks require a choice before any row or work exists; one batch choice applies to each
/// multi-track file; a later file without that track fails instead of falling back; Retry reuses the choice.
@MainActor
final class AudioTrackSelectionFlowTests: XCTestCase {
    private func makeHarness(
        center: TranscriptionJobCenter
    ) throws -> (PipelineHarness, FakeTrackProbe) {
        let probe = FakeTrackProbe()
        let harness = try PipelineHarness(testCase: self, trackProbe: probe, onProgress: center.progressHandler)
        return (harness, probe)
    }

    func testSingleTrackFilesStartWithoutAChoice() async throws {
        let center = TranscriptionJobCenter()
        let (h, probe) = try makeHarness(center: center)

        center.start(filesAt: [try h.makeMediaFile(named: "memo.m4a", audioTracks: 1)], pipeline: h.pipeline)
        await center.waitUntilIdle()

        XCTAssertNil(center.pendingAudioTrackSelection)
        XCTAssertEqual(probe.callCount, 1)
        let rows = try await h.store.fetchAll()
        XCTAssertEqual(rows.map(\.status), [.completed])
        XCTAssertEqual(rows.map(\.audioTrackOrdinal), [nil], "automatic selection")
        let ordinals = await h.normalizer.requestedOrdinals
        XCTAssertEqual(ordinals, [nil])
    }

    func testTwoTracksWaitForAChoiceBeforeAnyRowOrWork() async throws {
        let scheduler = FakeContinuedProcessingScheduler()
        let center = TranscriptionJobCenter(continuedProcessing: scheduler)
        let (h, _) = try makeHarness(center: center)

        center.start(filesAt: [try h.makeMediaFile(named: "Clinic talk.mov", audioTracks: 2)], pipeline: h.pipeline)
        await center.waitUntilIdle()

        let request = try XCTUnwrap(center.pendingAudioTrackSelection)
        XCTAssertEqual(request.fileName, "Clinic talk.mov")
        XCTAssertEqual(request.fileCount, 1)
        XCTAssertFalse(request.isBatch)
        XCTAssertEqual(request.tracks.map(\.displayName), ["Track 1 — English (Default)", "Track 2 — Spanish"])
        let rowsBefore = try await h.store.fetchAll()
        XCTAssertTrue(rowsBefore.isEmpty, "no row before the choice")
        let startedBefore = await h.normalizer.startedOutputURLs
        XCTAssertTrue(startedBefore.isEmpty, "no work before the choice")
        XCTAssertTrue(scheduler.submissions.isEmpty, "the background request is submitted by the choice, a tap")

        center.selectAudioTrack(1, for: request.id)
        XCTAssertNil(center.pendingAudioTrackSelection)
        XCTAssertEqual(scheduler.submissions.map(\.title), ["Clinic talk"])
        await center.waitUntilIdle()

        let rows = try await h.store.fetchAll()
        XCTAssertEqual(rows.map(\.status), [.completed])
        XCTAssertEqual(rows.map(\.audioTrackOrdinal), [1], "the choice is stored on the row")
        let ordinals = await h.normalizer.requestedOrdinals
        XCTAssertEqual(ordinals, [1])
    }

    func testABatchChoiceAppliesOnlyToItsMultiTrackFiles() async throws {
        let center = TranscriptionJobCenter()
        let (h, _) = try makeHarness(center: center)
        let files = [
            try h.makeMediaFile(named: "memo.m4a", audioTracks: 1),
            try h.makeMediaFile(named: "movie.mov", audioTracks: 2),
            try h.makeMediaFile(named: "lecture.mov", audioTracks: 3),
        ]

        center.start(filesAt: files, pipeline: h.pipeline)
        await center.waitUntilIdle()
        let request = try XCTUnwrap(center.pendingAudioTrackSelection)
        XCTAssertEqual(request.fileName, "movie.mov", "the first multi-track file's tracks are offered")
        XCTAssertEqual(request.fileCount, 3)
        XCTAssertTrue(request.isBatch)

        center.selectAudioTrack(1, for: request.id)
        await center.waitUntilIdle()

        let rows = try await h.store.fetchAll()
        let byName = Dictionary(uniqueKeysWithValues: rows.map { ($0.fileName, $0) })
        XCTAssertNil(byName["memo.m4a"]?.audioTrackOrdinal, "a single-track file keeps automatic selection")
        XCTAssertEqual(byName["movie.mov"]?.audioTrackOrdinal, 1)
        XCTAssertEqual(byName["lecture.mov"]?.audioTrackOrdinal, 1)
        XCTAssertEqual(rows.map(\.status), [.completed, .completed, .completed])
    }

    func testALaterFileWithoutTheChosenTrackFailsAndNeverFallsBack() async throws {
        let center = TranscriptionJobCenter()
        let (h, _) = try makeHarness(center: center)
        let files = [
            try h.makeMediaFile(named: "three.mov", audioTracks: 3),
            try h.makeMediaFile(named: "two.mov", audioTracks: 2),
        ]

        center.start(filesAt: files, pipeline: h.pipeline)
        await center.waitUntilIdle()
        let request = try XCTUnwrap(center.pendingAudioTrackSelection)
        XCTAssertEqual(request.tracks.count, 3)
        center.selectAudioTrack(2, for: request.id)
        await center.waitUntilIdle()

        let rows = try await h.store.fetchAll()
        let byName = Dictionary(uniqueKeysWithValues: rows.map { ($0.fileName, $0) })
        XCTAssertEqual(byName["three.mov"]?.status, .completed)
        let two = try XCTUnwrap(byName["two.mov"])
        XCTAssertEqual(two.status, .failed, "the rest of the batch continues; this file fails")
        XCTAssertEqual(two.audioTrackOrdinal, 2)
        XCTAssertEqual(
            two.errorMessage,
            AudioTrackSelectionError.trackMissing(ordinal: 2, trackCount: 2).errorDescription)
        let transcribed = await h.speech.transcribeCalls
        XCTAssertEqual(transcribed, 1, "no other track was transcribed in its place")
    }

    func testCancellingTheChoiceDropsTheBatchAndSettlesItsFiles() async throws {
        let center = TranscriptionJobCenter()
        let (h, _) = try makeHarness(center: center)
        var settled: [URL] = []
        center.onImportSettled = { settled.append($0) }
        let files = [
            try h.makeMediaFile(named: "memo.m4a", audioTracks: 1),
            try h.makeMediaFile(named: "movie.mov", audioTracks: 2),
        ]

        center.start(filesAt: files, pipeline: h.pipeline)
        await center.waitUntilIdle()
        let request = try XCTUnwrap(center.pendingAudioTrackSelection)
        center.cancelAudioTrackSelection(request.id)
        await center.waitUntilIdle()

        XCTAssertNil(center.pendingAudioTrackSelection)
        XCTAssertEqual(settled, files, "each file counts as settled, so its Inbox copy can go")
        let rows = try await h.store.fetchAll()
        XCTAssertTrue(rows.isEmpty, "nothing was imported")
        XCTAssertTrue(fileExists(files[0]) && fileExists(files[1]), "the job center never deletes a file itself")
    }

    func testRetryReusesTheStoredChoice() async throws {
        let center = TranscriptionJobCenter()
        let (h, _) = try makeHarness(center: center)
        await h.speech.failTranscription(with: FakeError(message: "engine hiccup"))
        center.start(filesAt: [try h.makeMediaFile(named: "movie.mov", audioTracks: 2)], pipeline: h.pipeline)
        await center.waitUntilIdle()
        let request = try XCTUnwrap(center.pendingAudioTrackSelection)
        center.selectAudioTrack(1, for: request.id)
        await center.waitUntilIdle()
        let fetchedId = try await h.store.fetchAll().first?.id
        let id = try XCTUnwrap(fetchedId)
        let failed = await h.store.row(id)
        XCTAssertEqual(failed?.status, .failed)

        await h.speech.failTranscription(with: nil)
        center.retry(id, pipeline: h.pipeline)
        await center.waitUntilIdle()

        let row = await h.store.row(id)
        XCTAssertEqual(row?.status, .completed)
        let ordinals = await h.normalizer.requestedOrdinals
        XCTAssertEqual(ordinals, [1, 1], "Retry decodes the same track, no new choice")
        XCTAssertNil(center.pendingAudioTrackSelection)
    }

    func testBatchesWaitTheirTurnAndStaleChoicesAreIgnored() async throws {
        let center = TranscriptionJobCenter()
        let (h, _) = try makeHarness(center: center)

        center.start(filesAt: [try h.makeMediaFile(named: "first.mov", audioTracks: 2)], pipeline: h.pipeline)
        await center.waitUntilIdle()
        center.start(filesAt: [try h.makeMediaFile(named: "second.mov", audioTracks: 2)], pipeline: h.pipeline)
        await center.waitUntilIdle()

        let first = try XCTUnwrap(center.pendingAudioTrackSelection)
        XCTAssertEqual(first.fileName, "first.mov", "the second batch waits its turn")
        center.selectAudioTrack(5, for: first.id)
        XCTAssertEqual(center.pendingAudioTrackSelection, first, "a track the file does not offer does nothing")
        center.selectAudioTrack(0, for: UUID())
        XCTAssertEqual(center.pendingAudioTrackSelection, first, "a stale request id does nothing")

        center.selectAudioTrack(0, for: first.id)
        let second = try XCTUnwrap(center.pendingAudioTrackSelection)
        XCTAssertEqual(second.fileName, "second.mov")
        center.cancelAudioTrackSelection(first.id)
        XCTAssertEqual(center.pendingAudioTrackSelection, second, "cancelling a stale request does nothing")
        center.selectAudioTrack(1, for: second.id)
        await center.waitUntilIdle()

        let rows = try await h.store.fetchAll()
        let byName = Dictionary(uniqueKeysWithValues: rows.map { ($0.fileName, $0.audioTrackOrdinal) })
        XCTAssertEqual(byName, ["first.mov": 0, "second.mov": 1])
    }

    func testAnUnreadableFileIsImportedAsUsualAndFailsOnItsRow() async throws {
        let center = TranscriptionJobCenter()
        let (h, _) = try makeHarness(center: center)

        center.start(filesAt: [h.inbox.appendingPathComponent("gone.m4a")], pipeline: h.pipeline)
        await center.waitUntilIdle()

        XCTAssertNil(center.pendingAudioTrackSelection, "a probe failure never asks for a choice")
        XCTAssertNotNil(center.lastImportError, "the import itself reports the missing file, as in M1")
    }

    func testPipelineWithoutAProbeListsNoTracks() async throws {
        let h = try PipelineHarness(testCase: self)
        XCTAssertFalse(h.pipeline.canInspectAudioTracks)
        let tracks = try await h.pipeline.audioTracks(in: try h.makeMediaFile(named: "movie.mov", audioTracks: 2))
        XCTAssertTrue(tracks.isEmpty)
    }

    func testImportStoresTheOrdinal() async throws {
        let h = try PipelineHarness(testCase: self)
        let id = try await h.pipeline.importFile(
            from: try h.makeMediaFile(named: "movie.mov", audioTracks: 2), audioTrackOrdinal: 1)
        let row = await h.store.row(id)
        XCTAssertEqual(row?.audioTrackOrdinal, 1)
        let automatic = try await h.importSample()
        let automaticRow = await h.store.row(automatic)
        XCTAssertNil(automaticRow?.audioTrackOrdinal)
    }
}
