// Fresh implementation for iChirp (review R1-1, R6a-8): the Library's and Capture's lists of transcriptions read
// only the columns a row shows, like `DeliverableListingStore` does for documents. No schema change.

import ChirpCore
import ChirpText
import Foundation
import GRDB

extension GRDBTranscriptionStore {
    public func fetchSummaries(limit: Int?) async throws -> [TranscriptionSummary] {
        try await database.writer.read { db in
            try TranscriptionListingQueries.summaries(db, limit: limit)
        }
    }

    /// Tracks only `TranscriptionListingQueries.observedRegion`: a notes keystroke or a word-timing write never
    /// re-reads the list. Latest value only, so a busy consumer gets the newest list instead of a queue of old ones.
    public func observeSummaries(limit: Int?) -> AsyncStream<[TranscriptionSummary]> {
        let writer = database.writer
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let observation = ValueObservation.tracking(
                regions: TranscriptionListingQueries.observedRegions,
                fetch: { db in try TranscriptionListingQueries.summaries(db, limit: limit) })
            let cancellable = observation.start(
                in: writer,
                scheduling: .async(onQueue: TranscriptionListingQueries.observationQueue),
                onError: { error in
                    TranscriptionListingQueries.logger.error(
                        "observe_summaries_failed error_type=\(String(describing: type(of: error)), privacy: .public)")
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

    public func searchTranscriptions(matching query: String) async throws -> Set<UUID> {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        return try await database.writer.read { db in
            try TranscriptionListingQueries.search(db, needle: needle)
        }
    }
}

/// The queries behind the transcription lists. They run inside GRDB's closures, on its queues, never on the caller's
/// actor; none compares a UUID with a raw SQL string (README).
enum TranscriptionListingQueries {
    /// Serial, as GRDB requires for `.async(onQueue:)`, so notifications never reorder.
    static let observationQueue = DispatchQueue(label: "com.ichirp.chirpstore.observeSummaries")
    static let logger = Log.logger("store")

    /// The columns a row shows, in the order `summary(from:)` reads them by position.
    private static let rowColumns = [
        "id", "createdAt", "sourceType", "fileName", "mediaRelativePath", "durationMs", "speakerCount", "status",
        "errorMessage", "titleOverride", "derivedTitle", "derivedSnippet", "isFavorite", "privacyClass",
        "isPartialAudio", "sourceURL", "sourceTitle", "documentFormat", "documentPages",
    ]

    /// What the list observation tracks: every column a row shows or counts from (`documentPages`, and the text of a
    /// document or text item for its word count), plus `speakers`, because a rename changes what the Library's search
    /// finds and the Library searches again when its rows change, and `textCorrections` (plan 025: a correction changes
    /// what search finds). Not `userNotes`, `updatedAt`, word timings,
    /// diarization or segments: a write of only those (a notes keystroke) never re-reads the list.
    static let observedRegions: [any DatabaseRegionConvertible] = [
        SQLRequest<Row>(
            sql: "SELECT "
                + (rowColumns + ["cleanTranscript", "rawTranscript", "speakers", "textCorrections"])
                .joined(separator: ", ") + " FROM transcriptions")
    ]

    /// `observedRegions` as one region (tests).
    static func observedRegion(_ db: Database) throws -> DatabaseRegion {
        try observedRegions.reduce(DatabaseRegion()) { region, convertible in
            region.union(try convertible.databaseRegion(db))
        }
    }

    /// Every row's summary, newest first, at most `limit`. Word timings, speakers, diarization and segments are never
    /// read; a PDF's pages only for their count and method; the text only of a document or text item without pages,
    /// for its word count. Columns are read by position (no `Decodable` pass). A row whose own columns this build
    /// cannot read is skipped and logged by id; a JSON column it cannot read never hides a row (opening the row reports
    /// it).
    static func summaries(_ db: Database, limit: Int?) throws -> [TranscriptionSummary] {
        let textOfTextOnlyRows = "sourceType IN ('document', 'text') AND documentPages IS NULL"
        let cursor = try Row.fetchCursor(
            db,
            sql: """
                SELECT \(rowColumns.joined(separator: ", ")),
                       CASE WHEN \(textOfTextOnlyRows) THEN cleanTranscript END,
                       CASE WHEN \(textOfTextOnlyRows) THEN rawTranscript END
                FROM transcriptions
                ORDER BY createdAt DESC
                LIMIT ?
                """,
            arguments: [limit.map { max(0, $0) } ?? -1])
        var result: [TranscriptionSummary] = []
        while let row = try cursor.next() {
            if let summary = summary(from: row) {
                result.append(summary)
            } else {
                // Log the id only: never a column's content.
                let id = UUID.fromDatabaseValue(row[0] as DatabaseValue)?.uuidString ?? "unreadable"
                logger.error("row_summary_skipped_unreadable id=\(id, privacy: .public)")
            }
        }
        return result
    }

    /// One summary from a row of `summaries(_:limit:)`; nil when a column every row has cannot be read by this build.
    /// Unknown values read as `TranscriptionRecord.toTranscription()` reads them.
    private static func summary(from row: Row) -> TranscriptionSummary? {
        guard let id = UUID.fromDatabaseValue(row[0] as DatabaseValue),
            let createdAt = Date.fromDatabaseValue(row[1] as DatabaseValue),
            let sourceType = String.fromDatabaseValue(row[2] as DatabaseValue),
            let fileName = String.fromDatabaseValue(row[3] as DatabaseValue),
            let status = String.fromDatabaseValue(row[7] as DatabaseValue),
            let isFavorite = Bool.fromDatabaseValue(row[12] as DatabaseValue),
            let privacyClass = String.fromDatabaseValue(row[13] as DatabaseValue),
            let isPartialAudio = Bool.fromDatabaseValue(row[14] as DatabaseValue)
        else { return nil }
        let readSourceType = Transcription.SourceType(rawValue: sourceType) ?? TranscriptionRecord.fallbackSourceType
        let pages = pageCounts(String.fromDatabaseValue(row[18] as DatabaseValue))
        let text = Transcription.displayText(
            cleanTranscript: String.fromDatabaseValue(row[19] as DatabaseValue),
            rawTranscript: String.fromDatabaseValue(row[20] as DatabaseValue))
        return TranscriptionSummary(
            id: id, createdAt: createdAt, sourceType: readSourceType, fileName: fileName,
            mediaRelativePath: String.fromDatabaseValue(row[4] as DatabaseValue),
            durationMs: Int.fromDatabaseValue(row[5] as DatabaseValue),
            speakerCount: Int.fromDatabaseValue(row[6] as DatabaseValue),
            status: Transcription.Status(rawValue: status) ?? TranscriptionRecord.fallbackStatus,
            errorMessage: String.fromDatabaseValue(row[8] as DatabaseValue),
            titleOverride: String.fromDatabaseValue(row[9] as DatabaseValue),
            derivedTitle: String.fromDatabaseValue(row[10] as DatabaseValue),
            derivedSnippet: String.fromDatabaseValue(row[11] as DatabaseValue),
            isFavorite: isFavorite,
            privacyClass: PrivacyClass(rawValue: privacyClass) ?? TranscriptionRecord.fallbackPrivacyClass,
            isPartialAudio: isPartialAudio,
            sourceURL: String.fromDatabaseValue(row[15] as DatabaseValue),
            sourceTitle: String.fromDatabaseValue(row[16] as DatabaseValue),
            documentFormat: String.fromDatabaseValue(row[17] as DatabaseValue).flatMap(DocumentFormat.init(rawValue:)),
            documentPageCount: pages.count, ocrPageCount: pages.ocr,
            // The query reads the text only for a document or text item without pages; every other row has none.
            textWordCount: TranscriptionSummary.wordCount(of: text))
    }

    /// A page as its row counts it: only its method is decoded, never its text.
    private struct PageMethod: Decodable {
        var method: String?
    }

    /// How many pages `json` holds and how many were read with OCR; (0, 0) when there are none or this build cannot
    /// read them (the row still lists; opening it reports the problem).
    private static func pageCounts(_ json: String?) -> (count: Int, ocr: Int) {
        guard let json, let pages = try? JSONDecoder().decode([PageMethod].self, from: Data(json.utf8)) else {
            return (0, 0)
        }
        return (pages.count, pages.filter { $0.method == DocumentPage.Method.ocr.rawValue }.count)
    }

    /// Ids of rows that match `needle` by `TranscriptionSearch`'s rule (the one `Transcription.matchesSearch` uses):
    /// the title as shown, the text as shown, the corrected text (plan 025), the file name, then the speakers' labels.
    /// Only those columns are read, and word timings only for a row with corrections; speakers this build cannot read
    /// count as none, and a row whose id or file name cannot be read is skipped.
    static func search(_ db: Database, needle: String) throws -> Set<UUID> {
        var ids = Set<UUID>()
        let cursor = try Row.fetchCursor(
            db,
            sql: """
                SELECT id, titleOverride, sourceTitle, derivedTitle, fileName, cleanTranscript, rawTranscript, speakers,
                       textCorrections, CASE WHEN textCorrections IS NOT NULL THEN wordTimestamps END
                FROM transcriptions
                """)
        while let row = try cursor.next() {
            guard let id = UUID.fromDatabaseValue(row[0] as DatabaseValue),
                let fileName = String.fromDatabaseValue(row[4] as DatabaseValue)
            else { continue }
            let title = Transcription.displayTitle(
                titleOverride: String.fromDatabaseValue(row[1] as DatabaseValue),
                sourceTitle: String.fromDatabaseValue(row[2] as DatabaseValue),
                derivedTitle: String.fromDatabaseValue(row[3] as DatabaseValue), fileName: fileName)
            let text = Transcription.displayText(
                cleanTranscript: String.fromDatabaseValue(row[5] as DatabaseValue),
                rawTranscript: String.fromDatabaseValue(row[6] as DatabaseValue))
            let speakers = String.fromDatabaseValue(row[7] as DatabaseValue)
            let corrections = String.fromDatabaseValue(row[8] as DatabaseValue)
            let words = String.fromDatabaseValue(row[9] as DatabaseValue)
            let found = TranscriptionSearch.matches(
                query: needle, displayTitle: title, displayText: text,
                correctedText: { correctedText(id: id, corrections: corrections, words: words) }, fileName: fileName,
                speakerLabels: { speakerLabels(speakers) })
            if found { ids.insert(id) }
        }
        return ids
    }

    /// The transcript with the person's corrections (`Transcription.plainText(.heard)`, the one accessor), or nil when
    /// it has none that apply (or its columns cannot be read: the text as stored is still searched).
    private static func correctedText(id: UUID, corrections: String?, words: String?) -> String? {
        guard let corrections, let words,
            let envelope = TranscriptionRecord.decodeCorrections(corrections, id: id), !envelope.items.isEmpty,
            let timings = try? JSONDecoder().decode([WordTimestamp].self, from: Data(words.utf8))
        else { return nil }
        var row = Transcription(id: id, fileName: "")
        row.wordTimestamps = timings
        row.textCorrections = envelope
        guard !TranscriptTokens.edits(of: row).isEmpty else { return nil }
        return row.plainText(.heard)
    }

    private struct SpeakerLabel: Decodable {
        var label: String
    }

    private static func speakerLabels(_ json: String?) -> [String] {
        guard let json, let speakers = try? JSONDecoder().decode([SpeakerLabel].self, from: Data(json.utf8)) else {
            return []
        }
        return speakers.map(\.label)
    }
}
