import ChirpCore
import XCTest

@testable import ChirpFeatures

/// `recording.lock` (spec/contracts/meeting-session-v1.md).
final class MeetingSessionLockStoreTests: XCTestCase {
    private var root: URL!
    private var paths: AppPaths!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingSessionLockStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        paths = AppPaths(root: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func lock(
        id: UUID = UUID(), launch: UUID, state: MeetingSessionState = .recording, startedAt: Date = Date()
    ) -> MeetingSessionLock {
        MeetingSessionLock(
            sessionId: id, startedAt: startedAt, launchId: launch, displayName: "Meeting", state: state,
            speechEngine: "fluidaudio.parakeet-tdt", speechEngineVariant: "v3", notes: "Agenda: budget")
    }

    func testRoundTripAndAtomicRewriteKeepEveryField() throws {
        let store = MeetingSessionLockStore(paths: paths)
        let written = lock(launch: store.launchId)
        try store.write(written)

        let read = try XCTUnwrap(store.read(sessionId: written.sessionId))
        XCTAssertEqual(read.sessionId, written.sessionId)
        XCTAssertEqual(read.state, .recording)
        XCTAssertEqual(read.speechEngine, "fluidaudio.parakeet-tdt")
        XCTAssertEqual(read.speechEngineVariant, "v3")
        XCTAssertEqual(read.privacyClass, .personal)
        XCTAssertEqual(read.notes, "Agenda: budget")
        XCTAssertEqual(read.startedAt.timeIntervalSince1970, written.startedAt.timeIntervalSince1970, accuracy: 1)

        let updated = try store.update(sessionId: written.sessionId) { $0.state = .awaitingTranscription }
        XCTAssertEqual(updated?.state, .awaitingTranscription)
        XCTAssertEqual(store.read(sessionId: written.sessionId)?.state, .awaitingTranscription)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: store.folder(for: written.sessionId).path)
        XCTAssertEqual(leftovers, [MeetingSessionFiles.lock], "the atomic write leaves no temporary file")
    }

    func testMalformedNotesLoseOnlyTheNotes() throws {
        let store = MeetingSessionLockStore(paths: paths)
        let id = UUID()
        try FileManager.default.createDirectory(at: store.folder(for: id), withIntermediateDirectories: true)
        let json = """
            {"schemaVersion":1,"sessionId":"\(id.uuidString)","startedAt":"2026-09-22T09:41:00Z",
             "launchId":"\(UUID().uuidString)","displayName":"Meeting","state":"recording",
             "speechEngine":"fluidaudio.parakeet-tdt","privacyClass":"clinical","notes":{"bad":true}}
            """
        try Data(json.utf8).write(to: store.lockURL(for: id))
        let read = try XCTUnwrap(store.read(sessionId: id))
        XCTAssertNil(read.notes)
        XCTAssertEqual(read.privacyClass, .clinical)
    }

    func testANewerSchemaIsOpaqueButStillCountsAsALockFile() throws {
        let store = MeetingSessionLockStore(paths: paths)
        var newer = lock(launch: UUID())
        newer.schemaVersion = MeetingSessionLock.currentSchemaVersion + 1
        try store.write(newer)
        XCTAssertNil(store.read(sessionId: newer.sessionId))
        XCTAssertTrue(store.discoverOrphans().isEmpty)
        XCTAssertTrue(store.hasLockFile(sessionId: newer.sessionId))
    }

    func testUnreadableLockIsNotAnOrphanButIsARetentionBarrier() throws {
        let store = MeetingSessionLockStore(paths: paths)
        let id = UUID()
        try FileManager.default.createDirectory(at: store.folder(for: id), withIntermediateDirectories: true)
        try Data().write(to: store.lockURL(for: id))
        XCTAssertNil(store.read(sessionId: id))
        XCTAssertTrue(store.hasLockFile(sessionId: id))
    }

    func testOrphansAreLocksFromOtherLaunchesOldestFirst() throws {
        let store = MeetingSessionLockStore(paths: paths)
        let earlierLaunch = UUID()
        let old = lock(launch: earlierLaunch, startedAt: Date(timeIntervalSince1970: 1_000))
        let newer = lock(
            launch: earlierLaunch, state: .awaitingTranscription, startedAt: Date(timeIntervalSince1970: 2_000))
        let mine = lock(launch: store.launchId)
        for item in [newer, mine, old] { try store.write(item) }
        // A folder that is not a meeting (a file import) is ignored.
        try FileManager.default.createDirectory(
            at: paths.mediaDirectory(for: UUID()), withIntermediateDirectories: true)

        let orphans = store.discoverOrphans()
        XCTAssertEqual(orphans.map(\.sessionId), [old.sessionId, newer.sessionId])
        XCTAssertFalse(orphans.contains { $0.sessionId == mine.sessionId }, "this launch's meeting is never an orphan")
    }

    func testDeleteRemovesOnlyTheLock() throws {
        let store = MeetingSessionLockStore(paths: paths)
        let written = lock(launch: store.launchId)
        try store.write(written)
        let audio = store.folder(for: written.sessionId).appendingPathComponent(MeetingSessionFiles.audio)
        try Data("audio".utf8).write(to: audio)
        try store.delete(sessionId: written.sessionId)
        try store.delete(sessionId: written.sessionId)  // missing is fine
        XCTAssertFalse(store.hasLockFile(sessionId: written.sessionId))
        XCTAssertTrue(FileManager.default.fileExists(atPath: audio.path))
    }
}
