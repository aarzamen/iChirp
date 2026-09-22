import ChirpCore
import GRDB
import XCTest

@testable import ChirpStore

/// M3: migration `v5-meetings` (userNotes, isPartialAudio, audioRemovedAt) and the meeting field-level writes
/// (spec/contracts/meeting-session-v1.md).
final class MeetingsMigrationTests: XCTestCase {
    func testMigrationIsNamedV5AndAddsThreeAdditiveColumns() throws {
        let database = try DatabaseManager.inMemory()
        let (columns, applied) = try database.writer.read { db in
            (try db.columns(in: "transcriptions"), try DatabaseManager.migrator.appliedIdentifiers(db))
        }
        XCTAssertTrue(applied.contains("v5-meetings"), "\(applied)")
        let notes = try XCTUnwrap(columns.first { $0.name == "userNotes" })
        XCTAssertFalse(notes.isNotNull)
        let partial = try XCTUnwrap(columns.first { $0.name == "isPartialAudio" })
        XCTAssertTrue(partial.isNotNull)
        XCTAssertEqual(partial.defaultValueSQL, "0")
        let removed = try XCTUnwrap(columns.first { $0.name == "audioRemovedAt" })
        XCTAssertFalse(removed.isNotNull)
    }

    /// A row written before M3 (schema up to v4) reads back unchanged with the new fields empty.
    func testRowsFromBeforeTheMigrationReadWithEmptyMeetingFields() throws {
        let queue = try DatabaseQueue()
        try DatabaseManager.migrator.migrate(queue, upTo: "v4-dictation-text")
        let id = UUID()
        let created = Date(timeIntervalSinceReferenceDate: 780_000_000)
        try queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO transcriptions
                        (id, createdAt, updatedAt, sourceType, fileName, status, rawTranscript, isFavorite, privacyClass)
                    VALUES (?, ?, ?, 'dictation', 'Dictation.wav', 'completed', 'hello', 0, 'personal')
                    """,
                arguments: [id, created, created])
        }
        try DatabaseManager.migrator.migrate(queue)
        let row = try XCTUnwrap(
            try queue.read { db in try TranscriptionRecord.fetchOne(db, key: id)?.toTranscription() })
        XCTAssertNil(row.userNotes)
        XCTAssertFalse(row.isPartialAudio)
        XCTAssertNil(row.audioRemovedAt)
        XCTAssertEqual(row.rawTranscript, "hello")
    }

    private func meetingRow(status: Transcription.Status = .processing) -> Transcription {
        let id = UUID()
        var row = Transcription(
            id: id, sourceType: .meeting, fileName: "Meeting.caf",
            mediaRelativePath: "media/\(id.uuidString)/meeting.caf", status: status)
        row.isPartialAudio = true
        return row
    }

    func testMeetingFieldsRoundTripAndNotesSurviveAPipelineSave() async throws {
        let store = GRDBTranscriptionStore(database: try DatabaseManager.inMemory())
        var row = meetingRow()
        row.userNotes = "typed while recording"
        try await store.insert(row)
        let inserted = try await store.fetch(id: row.id)
        XCTAssertEqual(inserted?.userNotes, "typed while recording")
        XCTAssertEqual(inserted?.isPartialAudio, true)

        // The person edits the notes while the final pass runs; the pass's save keeps the edit.
        _ = try await store.updateUserNotes(id: row.id, userNotes: "edited during the final pass")
        row.status = .completed
        row.rawTranscript = "we agreed"
        row.userNotes = "stale copy from the job"
        let saved = try await store.savePreservingUserMetadata(row)
        XCTAssertEqual(saved?.userNotes, "edited during the final pass")
        XCTAssertEqual(saved?.status, .completed)
        XCTAssertEqual(saved?.isPartialAudio, true)
    }

    func testRenameSpeakerChangesTheRosterAndEverySegmentOfThatSpeakerOnly() async throws {
        let store = GRDBTranscriptionStore(database: try DatabaseManager.inMemory())
        var row = meetingRow(status: .completed)
        row.speakers = [SpeakerInfo(id: "S1", label: "Speaker 1"), SpeakerInfo(id: "S2", label: "Speaker 2")]
        row.transcriptSegments = [
            TranscriptSegmentRecord(
                startMs: 0, endMs: 900, speakerId: "S1", speakerLabel: "Speaker 1", text: "Hello",
                wordRange: TranscriptSegmentWordRange(startIndex: 0, endIndexExclusive: 1)),
            TranscriptSegmentRecord(
                startMs: 1_000, endMs: 1_900, speakerId: "S2", speakerLabel: "Speaker 2", text: "Hi",
                wordRange: TranscriptSegmentWordRange(startIndex: 1, endIndexExclusive: 2)),
            TranscriptSegmentRecord(
                startMs: 2_000, endMs: 2_900, speakerId: "S1", speakerLabel: "Speaker 1", text: "Agenda",
                wordRange: TranscriptSegmentWordRange(startIndex: 2, endIndexExclusive: 3)),
        ]
        try await store.insert(row)

        let renamed = try await store.renameSpeaker(id: row.id, speakerId: "S1", to: "  Dana  ")
        XCTAssertEqual(renamed?.speakers?.map(\.label), ["Dana", "Speaker 2"])
        XCTAssertEqual(renamed?.transcriptSegments?.map(\.speakerLabel), ["Dana", "Speaker 2", "Dana"])

        let unknown = try await store.renameSpeaker(id: row.id, speakerId: "S9", to: "Nobody")
        XCTAssertNil(unknown)
        let blank = try await store.renameSpeaker(id: row.id, speakerId: "S2", to: "   ")
        XCTAssertNil(blank, "a blank name is refused, nothing written")
        let stored = try await store.fetch(id: row.id)
        XCTAssertEqual(stored?.speakers?.map(\.label), ["Dana", "Speaker 2"])
    }

    func testMarkAudioRemovedOnlyOnACompletedRow() async throws {
        let store = GRDBTranscriptionStore(database: try DatabaseManager.inMemory())
        let processing = meetingRow()
        let completed = meetingRow(status: .completed)
        try await store.insert(processing)
        try await store.insert(completed)
        let when = Date(timeIntervalSinceReferenceDate: 800_000_000)

        let refused = try await store.markAudioRemoved(id: processing.id, at: when)
        XCTAssertNil(refused)
        let stillThere = try await store.fetch(id: processing.id)
        XCTAssertNotNil(stillThere?.mediaRelativePath)

        let removed = try await store.markAudioRemoved(id: completed.id, at: when)
        XCTAssertNil(removed?.mediaRelativePath)
        XCTAssertEqual(
            removed?.audioRemovedAt?.timeIntervalSinceReferenceDate ?? 0, when.timeIntervalSinceReferenceDate,
            accuracy: 0.01)
    }
}
