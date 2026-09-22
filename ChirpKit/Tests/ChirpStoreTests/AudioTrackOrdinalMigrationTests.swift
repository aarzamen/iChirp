import ChirpCore
import GRDB
import XCTest

@testable import ChirpStore

/// M1.5 Step 4: migration `v2-audio-track-ordinal` adds one nullable column; rows written before it decode as
/// automatic selection (nil), and an explicit ordinal survives every write path (contract
/// `spec/contracts/file-transcription-audio-tracks-v1.md`).
final class AudioTrackOrdinalMigrationTests: XCTestCase {
    func testMigrationAddsANullableIntegerColumn() throws {
        let database = try DatabaseManager.inMemory()
        let column = try database.writer.read { db in
            try db.columns(in: "transcriptions").first { $0.name == "audioTrackOrdinal" }
        }
        let audioTrackOrdinal = try XCTUnwrap(column, "the column exists after migrating")
        XCTAssertEqual(audioTrackOrdinal.type.uppercased(), "INTEGER")
        XCTAssertFalse(audioTrackOrdinal.isNotNull, "nullable: NULL means automatic selection")
        XCTAssertNil(audioTrackOrdinal.defaultValueSQL)

        let applied = try database.writer.read { db in try DatabaseManager.migrator.appliedIdentifiers(db) }
        XCTAssertTrue(applied.isSuperset(of: ["v1-transcriptions", "v2-audio-track-ordinal"]), "\(applied)")
    }

    /// A row written by an M1 build (schema v1 only) reads back after the migration with every field intact and
    /// `audioTrackOrdinal == nil`.
    func testRowsFromBeforeTheMigrationDecodeAsAutomatic() throws {
        let queue = try DatabaseQueue()
        try DatabaseManager.migrator.migrate(queue, upTo: "v1-transcriptions")
        let id = UUID()
        let created = Date(timeIntervalSinceReferenceDate: 780_000_000)
        try queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO transcriptions
                        (id, createdAt, updatedAt, sourceType, fileName, mediaRelativePath, durationMs, status,
                         rawTranscript, isFavorite, privacyClass)
                    VALUES (?, ?, ?, 'file', 'Old memo.m4a', ?, 4200, 'completed', 'hello world', 1, 'personal')
                    """,
                arguments: [id, created, created, "media/\(id.uuidString)/source.m4a"])
        }

        try DatabaseManager.migrator.migrate(queue)

        let row = try queue.read { db in try TranscriptionRecord.fetchOne(db, key: id)?.toTranscription() }
        let old = try XCTUnwrap(row)
        XCTAssertNil(old.audioTrackOrdinal)
        XCTAssertEqual(old.fileName, "Old memo.m4a")
        XCTAssertEqual(old.rawTranscript, "hello world")
        XCTAssertEqual(old.status, .completed)
        XCTAssertTrue(old.isFavorite)
    }

    func testExplicitOrdinalRoundTripsAndSurvivesEveryWritePath() async throws {
        let store = GRDBTranscriptionStore(database: try DatabaseManager.inMemory())
        let id = UUID()
        var row = Transcription(
            id: id, fileName: "Two tracks.mov", mediaRelativePath: "media/\(id.uuidString)/source.mov",
            audioTrackOrdinal: 1, status: .processing)
        try await store.insert(row)
        let inserted = try await store.fetch(id: id)
        XCTAssertEqual(inserted?.audioTrackOrdinal, 1)

        row.rawTranscript = "segunda pista"
        row.status = .completed
        let saved = try await store.savePreservingUserMetadata(row)
        XCTAssertEqual(saved?.audioTrackOrdinal, 1)

        let favorited = try await store.updateFavorite(id: id, isFavorite: true)
        XCTAssertEqual(favorited?.audioTrackOrdinal, 1)
        let failed = try await store.transitionStatus(
            id: id, from: [.completed], to: .failed, errorMessage: "for the test")
        XCTAssertEqual(failed?.audioTrackOrdinal, 1)
        let retried = try await store.transitionStatus(
            id: id, from: [.failed], to: .processing, errorMessage: nil)
        XCTAssertEqual(retried?.audioTrackOrdinal, 1, "Retry reuses the explicit choice")

        let listed = try await store.fetchAll()
        XCTAssertEqual(listed.map(\.audioTrackOrdinal), [1])
    }

    func testAutomaticSelectionStaysNil() async throws {
        let store = GRDBTranscriptionStore(database: try DatabaseManager.inMemory())
        let row = Transcription(fileName: "memo.m4a")
        try await store.insert(row)
        let fetched = try await store.fetch(id: row.id)
        XCTAssertNil(fetched?.audioTrackOrdinal)
    }
}
