import ChirpCore
import GRDB
import XCTest

@testable import ChirpStore

/// Plan 025 Step A2: `v11-transcript-corrections` adds one nullable TEXT column, `transcriptions.textCorrections`;
/// every earlier row reads nil and no existing value changes. Synthetic text only.
final class TranscriptCorrectionsMigrationTests: XCTestCase {
    private let id = UUID()
    private let created = Date(timeIntervalSinceReferenceDate: 780_000_000)

    private func makeV10Database() throws -> DatabaseQueue {
        var config = Configuration()
        config.foreignKeysEnabled = true
        let queue = try DatabaseQueue(configuration: config)
        try DatabaseManager.migrator.migrate(queue, upTo: "v10-deliverable-cut-off")
        try queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO transcriptions
                        (id, createdAt, updatedAt, sourceType, fileName, status, rawTranscript, wordTimestamps,
                         isFavorite, privacyClass)
                    VALUES (?, ?, ?, 'file', 'Synthetic visit.m4a', 'completed', 'Synthetic visit.',
                            '[{"word":"Synthetic","startMs":0,"endMs":300,"confidence":0.9},
                              {"word":"visit.","startMs":300,"endMs":600,"confidence":0.9}]', 0, 'personal')
                    """,
                arguments: [id, created, created])
        }
        return queue
    }

    func testMigrationAddsOneNullableTextColumn() throws {
        let queue = try makeV10Database()
        let before = try queue.read { db in try db.columns(in: "transcriptions").map(\.name) }
        XCTAssertFalse(before.contains("textCorrections"))
        _ = try DatabaseManager(writer: queue)
        let after = try queue.read { db in try db.columns(in: "transcriptions") }
        XCTAssertEqual(after.map(\.name), before + ["textCorrections"], "exactly one new column, at the end")
        let column = try XCTUnwrap(after.first { $0.name == "textCorrections" })
        XCTAssertEqual(column.type.uppercased(), "TEXT")
        XCTAssertFalse(column.isNotNull)
        let applied = try queue.read { db in try DatabaseManager.migrator.appliedIdentifiers(db) }
        XCTAssertTrue(applied.contains("v11-transcript-corrections"))
    }

    func testRowsFromBeforeTheMigrationReadNil() async throws {
        let queue = try makeV10Database()
        let before = try queue.read { db in try Row.fetchAll(db, sql: "SELECT * FROM transcriptions") }
        let store = GRDBTranscriptionStore(database: try DatabaseManager(writer: queue))
        let row = try await store.fetch(id: id)
        XCTAssertNil(row?.textCorrections)
        XCTAssertEqual(row?.rawTranscript, "Synthetic visit.")
        let after = try await queue.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT \(before.first!.columnNames.joined(separator: ", ")) FROM transcriptions")
        }
        XCTAssertEqual(after, before, "no existing value changes")
        let stored = try await queue.read { db in
            try String.fetchOne(db, sql: "SELECT textCorrections FROM transcriptions")
        }
        XCTAssertNil(stored)
    }
}
