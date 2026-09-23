import ChirpCore
import GRDB
import XCTest

@testable import ChirpStore

/// Plan 022 Step 1: a typed or pasted text item needs no new column (`sourceType` is free text since v1).
final class TextItemStoreTests: XCTestCase {
    func testTextItemRoundTripsThroughTheStore() async throws {
        let database = try DatabaseManager.inMemory()
        let store = GRDBTranscriptionStore(database: database)
        var row = Transcription(
            createdAt: Date(timeIntervalSinceReferenceDate: 780_000_000), sourceType: .text, fileName: "Text",
            status: .completed, privacyClass: .clinical)
        row.rawTranscript = "Synthetic heading\nA synthetic line of typed text."
        row.derivedTitle = "Synthetic heading"
        row.derivedSnippet = "A synthetic line of typed text."

        try await store.insert(row)
        let fetched = try await store.fetch(id: row.id)
        XCTAssertEqual(fetched, row)
        XCTAssertEqual(fetched?.sourceType, .text)
        XCTAssertEqual(fetched?.displayTitle, "Synthetic heading")

        let rawValue = try await database.writer.read { db in
            try String.fetchOne(db, sql: "SELECT sourceType FROM transcriptions")
        }
        XCTAssertEqual(rawValue, "text")

        let all = try await store.fetchAll()
        XCTAssertEqual(all.map(\.id), [row.id])
    }
}
