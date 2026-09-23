// Fresh implementation for iChirp (plan 023, UX audit F43): the Library's read-only lists of generated documents.
// Reads the `deliverables` table of `v3-language-models` as it is (no schema change). Contract:
// spec/contracts/deliverables-v1.md ("Listing").

import ChirpCore
import Foundation
import GRDB

extension GRDBDeliverableStore: DeliverableListing {
    public func fetchDeliverableSummaries() async throws -> [DeliverableSummary] {
        try await listingDatabase.writer.read { db in
            try DeliverableListingQueries.summaries(db)
        }
    }

    public func observeDeliverableSummaries() -> AsyncStream<[DeliverableSummary]> {
        let writer = listingDatabase.writer
        return AsyncStream { continuation in
            // Tracks the `deliverables` table, so a transcript's delete (its documents cascade) is seen too.
            let observation = ValueObservation.tracking { db in
                try DeliverableListingQueries.summaries(db)
            }
            let cancellable = observation.start(
                in: writer,
                scheduling: .async(onQueue: DeliverableListingQueries.observationQueue),
                onError: { error in
                    DeliverableListingQueries.logger.error(
                        "observe_documents_failed error_type=\(String(describing: type(of: error)), privacy: .public)")
                    continuation.finish()
                },
                onChange: { summaries in
                    continuation.yield(summaries)
                }
            )
            continuation.onTermination = { _ in
                cancellable.cancel()
            }
        }
    }

    public func searchDeliverables(matching query: String) async throws -> Set<UUID> {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        return try await listingDatabase.writer.read { db in
            try DeliverableListingQueries.search(db, needle: needle)
        }
    }
}

/// The queries behind `DeliverableListing`. They run inside GRDB's closures, on its queues, never on the caller's
/// actor; none compares a UUID with a raw SQL string (README).
enum DeliverableListingQueries {
    /// Serial, as GRDB requires for `.async(onQueue:)`, so notifications never reorder.
    static let observationQueue = DispatchQueue(label: "com.ichirp.chirpstore.observeDocuments")
    static let logger = Log.logger("store")

    /// Every document's summary, newest first. Only the start of each text is read, and columns are read by position
    /// (no `Decodable` pass), because the Library re-reads this list after every change to a document.
    static func summaries(_ db: Database) throws -> [DeliverableSummary] {
        let cursor = try Row.fetchCursor(
            db,
            sql: """
                SELECT id, transcriptionId, promptId, title, privacyClass, provider, locality, createdAt, updatedAt,
                       editedAt, substr(text, 1, ?)
                FROM deliverables
                ORDER BY createdAt DESC, id
                """,
            arguments: [DeliverableSummary.textStartLength])
        var result: [DeliverableSummary] = []
        while let row = try cursor.next() {
            if let summary = summary(from: row) {
                result.append(summary)
            } else {
                // Skip one unreadable row rather than empty the list; log its id only (never a column's content).
                let id = UUID.fromDatabaseValue(row[0] as DatabaseValue)?.uuidString ?? "unreadable"
                logger.error("document_row_skipped_unreadable id=\(id, privacy: .public)")
            }
        }
        return result
    }

    /// One summary from a row of `summaries(_:)`; nil when a required column cannot be read by this build.
    private static func summary(from row: Row) -> DeliverableSummary? {
        guard let id = UUID.fromDatabaseValue(row[0] as DatabaseValue),
            let transcriptionID = UUID.fromDatabaseValue(row[1] as DatabaseValue),
            let title = String.fromDatabaseValue(row[3] as DatabaseValue),
            let privacyClass = String.fromDatabaseValue(row[4] as DatabaseValue),
            let provider = String.fromDatabaseValue(row[5] as DatabaseValue),
            let locality = String.fromDatabaseValue(row[6] as DatabaseValue),
            let createdAt = Date.fromDatabaseValue(row[7] as DatabaseValue),
            let updatedAt = Date.fromDatabaseValue(row[8] as DatabaseValue)
        else { return nil }
        return DeliverableSummary(
            id: id, transcriptionID: transcriptionID,
            promptID: UUID.fromDatabaseValue(row[2] as DatabaseValue),
            title: title,
            // The same fallbacks as `DeliverableRecord.toDeliverable()`: unknown reads as the most protective.
            privacyClass: PrivacyClass(rawValue: privacyClass) ?? .clinical,
            provider: provider,
            locality: EngineLocality(rawValue: locality) ?? .cloud,
            createdAt: createdAt, updatedAt: updatedAt,
            editedAt: Date.fromDatabaseValue(row[9] as DatabaseValue),
            textStart: String.fromDatabaseValue(row[10] as DatabaseValue) ?? "")
    }

    /// Ids of documents whose title or text contains `needle`, ignoring case. An ASCII query uses SQLite's `LIKE`
    /// (case-insensitive for ASCII, and fast over thousands of documents); any other query compares in Swift with
    /// `localizedCaseInsensitiveContains`, the Library's rule for transcripts, so "José" finds "JOSÉ".
    static func search(_ db: Database, needle: String) throws -> Set<UUID> {
        if needle.allSatisfy(\.isASCII) {
            let pattern = "%" + escapeLike(needle) + "%"
            let request =
                DeliverableRecord
                .select(Column("id"), as: UUID.self)
                .filter(Column("title").like(pattern, escape: "\\") || Column("text").like(pattern, escape: "\\"))
            return Set(try request.fetchAll(db))
        }
        var ids = Set<UUID>()
        let cursor = try Row.fetchCursor(db, sql: "SELECT id, title, text FROM deliverables")
        while let row = try cursor.next() {
            guard let found = try? SearchRow(row: row) else { continue }
            if found.title.localizedCaseInsensitiveContains(needle)
                || found.text.localizedCaseInsensitiveContains(needle)
            {
                ids.insert(found.id)
            }
        }
        return ids
    }

    /// `%`, `_` and the escape character itself match literally.
    static func escapeLike(_ text: String) -> String {
        var escaped = ""
        for character in text {
            if character == "\\" || character == "%" || character == "_" { escaped.append("\\") }
            escaped.append(character)
        }
        return escaped
    }

    private struct SearchRow: Decodable, FetchableRecord {
        var id: UUID
        var title: String
        var text: String
    }
}
