import ChirpCore
import XCTest

@testable import ChirpFeatures

/// M3 Step 3: recovery from fixture folders a killed launch leaves behind (synthetic audio, fake engines).
@MainActor
final class MeetingRecoveryServiceTests: XCTestCase {
    private var harness: MeetingHarness!

    override func tearDown() async throws {
        harness?.cleanUp()
        harness = nil
    }

    private func service(_ h: MeetingHarness) -> MeetingRecoveryService {
        MeetingRecoveryService(
            paths: h.paths, store: h.store, lockStore: h.lockStore, finalizer: h.finalizer, normalizer: h.normalizer)
    }

    func testDiscoveryOffersOrphansAndNeverThisLaunchsMeeting() async throws {
        let h = try MeetingHarness()
        harness = h
        let killedWhileRecording = try h.makeOrphan(state: .recording, startedAt: Date(timeIntervalSince1970: 100))
        let killedWhileTranscribing = try h.makeOrphan(
            state: .awaitingTranscription, startedAt: Date(timeIntervalSince1970: 200))
        var interrupted = Transcription(
            id: killedWhileTranscribing, sourceType: .meeting, fileName: "Meeting",
            mediaRelativePath: "media/\(killedWhileTranscribing.uuidString)/meeting.caf", status: .interrupted)
        interrupted.userNotes = "kept"
        try await h.store.insert(interrupted)
        // This launch's own recording is never offered.
        h.coordinator.start()
        await waitUntil { h.coordinator.state == .recording }

        let pending = await service(h).discoverPendingRecoveries()
        XCTAssertEqual(pending.map(\.id), [killedWhileRecording, killedWhileTranscribing])
        XCTAssertEqual(pending.map(\.isPartialAudio), [true, false])
        XCTAssertEqual(pending.first?.audioDurationMs, FakeNormalizer.durationMs)
        XCTAssertEqual(pending.first?.hasNotes, true)
        XCTAssertEqual(pending.last?.rowStatus, .interrupted)
        h.coordinator.discard()
        await h.coordinator.settle()
    }

    func testRecoverInsertsAPartialAudioRowWithTheLockNotesAndFinalizes() async throws {
        let h = try MeetingHarness()
        harness = h
        let id = try h.makeOrphan(state: .recording, notes: "typed before the crash")
        let recovery = service(h)

        let saved = await recovery.recover(id)

        XCTAssertEqual(saved?.status, .completed)
        XCTAssertEqual(saved?.sourceType, .meeting)
        XCTAssertEqual(saved?.isPartialAudio, true, "the kill cut the recording")
        XCTAssertEqual(saved?.userNotes, "typed before the crash")
        XCTAssertEqual(saved?.rawTranscript, FakeSpeech.helloText)
        XCTAssertEqual(saved?.mediaRelativePath, "media/\(id.uuidString)/meeting.caf")
        XCTAssertFalse(h.lockStore.hasLockFile(sessionId: id), "settled after the completed save")
        XCTAssertTrue(fileExists(h.audio(id)))
        XCTAssertFalse(fileExists(h.folder(id).appendingPathComponent(MeetingSessionFiles.chunks)))
        let again = await recovery.discoverPendingRecoveries()
        XCTAssertTrue(again.isEmpty)
    }

    func testRecoverReusesTheInterruptedRowAfterAStopAndIsNotPartial() async throws {
        let h = try MeetingHarness()
        harness = h
        let id = try h.makeOrphan(state: .awaitingTranscription)
        try await h.store.insert(
            Transcription(
                id: id, sourceType: .meeting, fileName: "Meeting",
                mediaRelativePath: "media/\(id.uuidString)/meeting.caf", status: .interrupted))
        let saved = await service(h).recover(id)
        XCTAssertEqual(saved?.status, .completed)
        XCTAssertEqual(saved?.isPartialAudio, false)
        XCTAssertEqual(saved?.userNotes, "orphan notes", "notes from the lock fill an empty row")
    }

    func testAFailedRecoveryKeepsTheLockAndAudioAndIsNotOfferedAgainOnlyRetried() async throws {
        let h = try MeetingHarness(speech: FakeSpeech(status: .notDownloaded))
        harness = h
        let id = try h.makeOrphan()
        let recovery = service(h)
        let failed = await recovery.recover(id)
        XCTAssertEqual(failed?.status, .failed)
        XCTAssertTrue(failed?.errorMessage?.contains("The recording is saved") ?? false)
        XCTAssertTrue(h.lockStore.hasLockFile(sessionId: id))
        XCTAssertTrue(fileExists(h.audio(id)))
        let pending = await recovery.discoverPendingRecoveries()
        XCTAssertTrue(pending.isEmpty, "claimed by this launch; a failed row is the Library's Retry")

        await h.speech.setStatus(.ready(bytesOnDisk: 1))
        let retried = await h.finalizer.retry(id: id)
        XCTAssertEqual(retried?.status, .completed)
        XCTAssertFalse(h.lockStore.hasLockFile(sessionId: id))
    }

    func testALockThatOutlivedACompletedSaveIsSettledNotOffered() async throws {
        let h = try MeetingHarness()
        harness = h
        let id = try h.makeOrphan(state: .awaitingTranscription)
        try await h.store.insert(
            Transcription(id: id, sourceType: .meeting, fileName: "Meeting", status: .completed))
        let pending = await service(h).discoverPendingRecoveries()
        XCTAssertTrue(pending.isEmpty)
        XCTAssertFalse(h.lockStore.hasLockFile(sessionId: id))
        XCTAssertTrue(fileExists(h.audio(id)), "settling removes the lock only")
    }

    func testDiscardRemovesTheRowAndTheWholeFolder() async throws {
        let h = try MeetingHarness()
        harness = h
        let id = try h.makeOrphan()
        try await h.store.insert(
            Transcription(id: id, sourceType: .meeting, fileName: "Meeting", status: .interrupted))
        let untouched = try h.makeOrphan()
        try await service(h).discard(id)
        XCTAssertFalse(fileExists(h.folder(id)))
        let row = try await h.store.fetch(id: id)
        XCTAssertNil(row)
        XCTAssertTrue(fileExists(h.audio(untouched)), "only the confirmed meeting is deleted")
    }

    func testAKilledMeetingWithoutAudioIsStillOfferedAndRecoverFailsHonestly() async throws {
        let h = try MeetingHarness()
        harness = h
        let id = try h.makeOrphan(withAudio: false)
        let pending = await service(h).discoverPendingRecoveries()
        XCTAssertEqual(pending.first?.id, id)
        XCTAssertNil(pending.first?.audioDurationMs)
        let result = await service(h).recover(id)
        XCTAssertEqual(result?.status, .failed)
        XCTAssertTrue(h.lockStore.hasLockFile(sessionId: id), "nothing is deleted without the person")
    }
}
