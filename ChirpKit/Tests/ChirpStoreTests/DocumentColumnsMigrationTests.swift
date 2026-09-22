import ChirpCore
import GRDB
import XCTest

@testable import ChirpStore

/// M5: migration `v6-documents` adds four nullable columns; earlier rows read nil, and the new fields survive every
/// write path (contract `spec/contracts/document-items-v1.md`).
final class DocumentColumnsMigrationTests: XCTestCase {
    func testMigrationAddsFourNullableTextColumns() throws {
        let database = try DatabaseManager.inMemory()
        let columns = try database.writer.read { db in try db.columns(in: "transcriptions") }
        for name in ["sourceURL", "sourceTitle", "documentFormat", "documentPages"] {
            let column = try XCTUnwrap(columns.first { $0.name == name }, name)
            XCTAssertEqual(column.type.uppercased(), "TEXT", name)
            XCTAssertFalse(column.isNotNull, name)
            XCTAssertNil(column.defaultValueSQL, name)
        }
        let applied = try database.writer.read { db in try DatabaseManager.migrator.appliedIdentifiers(db) }
        XCTAssertTrue(applied.contains("v6-documents"), "\(applied)")
    }

    func testRowsFromBeforeTheMigrationReadNil() throws {
        let queue = try DatabaseQueue()
        try DatabaseManager.migrator.migrate(queue, upTo: "v4-dictation-text")
        let id = UUID()
        let created = Date(timeIntervalSinceReferenceDate: 780_000_000)
        try queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO transcriptions
                        (id, createdAt, updatedAt, sourceType, fileName, status, rawTranscript, isFavorite,
                         privacyClass)
                    VALUES (?, ?, ?, 'file', 'Old memo.m4a', 'completed', 'hello world', 0, 'personal')
                    """,
                arguments: [id, created, created])
        }
        try DatabaseManager.migrator.migrate(queue)
        let row = try XCTUnwrap(
            try queue.read { db in try TranscriptionRecord.fetchOne(db, key: id)?.toTranscription() })
        XCTAssertNil(row.sourceURL)
        XCTAssertNil(row.sourceTitle)
        XCTAssertNil(row.documentFormat)
        XCTAssertNil(row.documentPages)
        XCTAssertEqual(row.displayTitle, "Old memo")
    }

    func testDocumentFieldsRoundTripAndSurviveWrites() async throws {
        let store = GRDBTranscriptionStore(database: try DatabaseManager.inMemory())
        let id = UUID()
        var row = Transcription(
            id: id, sourceType: .document, fileName: "Synthetic handout.pdf",
            mediaRelativePath: "media/\(id.uuidString)/source.pdf", status: .processing)
        row.documentFormat = .pdf
        try await store.insert(row)

        row.rawTranscript = "Page one text.\n\nPage two text."
        row.documentPages = [
            DocumentPage(number: 1, text: "Page one text.", method: .textLayer),
            DocumentPage(number: 2, text: "Page two text.", method: .ocr),
        ]
        row.sourceTitle = "A Synthetic Handout"
        row.status = .completed
        let savedRow = try await store.savePreservingUserMetadata(row)
        let saved = try XCTUnwrap(savedRow)
        XCTAssertEqual(saved.documentFormat, .pdf)
        XCTAssertEqual(saved.documentPages?.map(\.method), [.textLayer, .ocr])
        XCTAssertEqual(saved.displayTitle, "A Synthetic Handout")
        XCTAssertEqual(saved.ocrPageCount, 1)

        let renamed = try await store.updateTitleOverride(id: id, titleOverride: "Mine")
        XCTAssertEqual(renamed?.displayTitle, "Mine", "the person's rename still wins")
        XCTAssertEqual(renamed?.documentPages?.count, 2)
        XCTAssertEqual(renamed?.sourceTitle, "A Synthetic Handout")
    }

    func testLinkProvenanceRoundTrips() async throws {
        let store = GRDBTranscriptionStore(database: try DatabaseManager.inMemory())
        var row = Transcription(sourceType: .podcast, fileName: "Episode.mp3", status: .processing)
        row.sourceURL = "https://podcasts.apple.com/us/podcast/x/id1?i=2"
        row.sourceTitle = "Episode 12: Synthetic"
        try await store.insert(row)
        let fetched = try await store.fetch(id: row.id)
        XCTAssertEqual(fetched?.sourceURL, row.sourceURL)
        XCTAssertEqual(fetched?.displayTitle, "Episode 12: Synthetic")
    }

    func testUnknownDocumentFormatReadsNilAndIsKeptOnWrite() async throws {
        let database = try DatabaseManager.inMemory()
        let store = GRDBTranscriptionStore(database: database)
        let row = Transcription(sourceType: .document, fileName: "Future.odt", status: .completed)
        try await store.insert(row)
        try await database.writer.write { db in
            try db.execute(
                sql: "UPDATE transcriptions SET documentFormat = 'odt', documentPages = ? WHERE rowid = 1",
                arguments: [#"[{"number":1,"text":"x","method":"future-method"}]"#])
        }
        let fetched = try await store.fetch(id: row.id)
        let read = try XCTUnwrap(fetched)
        XCTAssertNil(read.documentFormat)
        XCTAssertEqual(read.documentPages?.first?.method, .textLayer, "an unknown method stays readable")
        _ = try await store.updateFavorite(id: row.id, isFavorite: true)
        let raw = try await database.writer.read { db in
            try String.fetchOne(db, sql: "SELECT documentFormat FROM transcriptions")
        }
        XCTAssertEqual(raw, "odt", "a newer build's format survives an older build's write")
    }
}
