import ChirpCore
import GRDB
import XCTest

@testable import ChirpStore

/// Review R1-1 and R6a-8: the Library's and Capture's lists read only what a row shows, never the word timings,
/// segments or pages, and a write a list does not show (notes) does not re-read them. Every row is synthetic.
final class TranscriptionSummaryStoreTests: XCTestCase {
    private var database: DatabaseManager!
    private var store: GRDBTranscriptionStore!
    private let base = Date(timeIntervalSinceReferenceDate: 780_000_000)

    override func setUp() async throws {
        database = try DatabaseManager.inMemory()
        store = GRDBTranscriptionStore(database: database)
    }

    // MARK: - Rows

    private func meeting(_ name: String, minute: Int) -> Transcription {
        var row = Transcription(
            createdAt: base.addingTimeInterval(Double(minute) * 60), sourceType: .meeting, fileName: "\(name).m4a",
            mediaRelativePath: "media/x/source.m4a", durationMs: 61_000, status: .completed, privacyClass: .personal)
        row.rawTranscript = "hello world"
        row.wordTimestamps = [
            WordTimestamp(word: "hello", startMs: 0, endMs: 400, confidence: 0.9, speakerId: "S1"),
            WordTimestamp(word: "world", startMs: 450, endMs: 900, confidence: 0.9, speakerId: "S2"),
        ]
        row.speakerCount = 2
        row.speakers = [SpeakerInfo(id: "S1", label: "Speaker 1"), SpeakerInfo(id: "S2", label: "Speaker 2")]
        row.diarizationSegments = [DiarizationSegmentRecord(speakerId: "S1", startMs: 0, endMs: 900)]
        row.transcriptSegments = [
            TranscriptSegmentRecord(
                startMs: 0, endMs: 900, speakerId: "S1", speakerLabel: "Speaker 1", text: "hello world",
                wordRange: TranscriptSegmentWordRange(startIndex: 0, endIndexExclusive: 2))
        ]
        row.derivedTitle = "Hello world"
        row.derivedSnippet = "hello world"
        return row
    }

    private func pdf(minute: Int) -> Transcription {
        var row = Transcription(
            createdAt: base.addingTimeInterval(Double(minute) * 60), sourceType: .document, fileName: "Handout.pdf",
            mediaRelativePath: "media/y/source.pdf", status: .completed, privacyClass: .clinical)
        row.documentFormat = .pdf
        row.rawTranscript = "Page one. Page two. Page three."
        row.documentPages = [
            DocumentPage(number: 1, text: "Page one.", method: .textLayer),
            DocumentPage(number: 2, text: "Page two.", method: .ocr),
            DocumentPage(number: 3, text: "Page three.", method: .empty),
        ]
        row.sourceTitle = "A Synthetic Handout"
        return row
    }

    private func wordDocument(minute: Int) -> Transcription {
        var row = Transcription(
            createdAt: base.addingTimeInterval(Double(minute) * 60), sourceType: .document, fileName: "Plan.docx",
            status: .completed)
        row.documentFormat = .docx
        row.rawTranscript = "Three synthetic words"
        return row
    }

    private func textItem(minute: Int) -> Transcription {
        var row = Transcription(
            createdAt: base.addingTimeInterval(Double(minute) * 60), sourceType: .text, fileName: "Typed text",
            status: .completed)
        row.rawTranscript = "um the zarelto dose"
        row.cleanTranscript = "the Xarelto dose today"
        row.isFavorite = true
        return row
    }

    private func failedDictation(minute: Int) -> Transcription {
        var row = Transcription(
            createdAt: base.addingTimeInterval(Double(minute) * 60), sourceType: .dictation,
            fileName: "Dictation.wav", status: .failed)
        row.errorMessage = "Synthetic failure"
        row.isPartialAudio = true
        return row
    }

    private func insert(_ rows: [Transcription]) async throws {
        for row in rows {
            try await store.insert(row)
        }
    }

    // MARK: - What a row shows

    func testSummariesCarryWhatARowShowsNewestFirst() async throws {
        let rows = [
            meeting("Standup", minute: 1), pdf(minute: 2), wordDocument(minute: 3), textItem(minute: 4),
            failedDictation(minute: 5),
        ]
        try await insert(rows)

        let summaries = try await store.fetchSummaries(limit: nil)

        XCTAssertEqual(summaries, rows.reversed().map(TranscriptionSummary.init), "the same values a full read gives")
        let byID = Dictionary(uniqueKeysWithValues: summaries.map { ($0.id, $0) })
        let handout = try XCTUnwrap(byID[rows[1].id])
        XCTAssertEqual(handout.documentPageCount, 3)
        XCTAssertEqual(handout.ocrPageCount, 1)
        XCTAssertEqual(handout.textWordCount, 0, "a PDF's row counts pages, not words")
        XCTAssertEqual(handout.displayTitle, "A Synthetic Handout")
        XCTAssertEqual(byID[rows[2].id]?.textWordCount, 3)
        XCTAssertEqual(byID[rows[3].id]?.textWordCount, 4, "the clean text, as the row shows it")
        XCTAssertEqual(byID[rows[0].id]?.textWordCount, 0, "a recording's row shows no word count")
        XCTAssertEqual(byID[rows[4].id]?.errorMessage, "Synthetic failure")
    }

    func testALimitReadsOnlyTheNewestRows() async throws {
        let rows = (0..<5).map { meeting("Item \($0)", minute: $0) }
        try await insert(rows)

        let recent = try await store.fetchSummaries(limit: 3)

        XCTAssertEqual(recent.map(\.id), rows.reversed().prefix(3).map(\.id))
    }

    // MARK: - Never decoded (the heart of R1-1)

    func testTheListNeverDecodesWordTimingsSpeakersSegmentsOrPages() async throws {
        let good = meeting("Good", minute: 1)
        let broken = meeting("Broken", minute: 2)
        try await insert([good, broken])
        try await tamper(broken.id) { record in
            // JSON this build cannot read at all: a full read of this row fails.
            record.wordTimestamps = "{not json"
            record.speakers = "{not json"
            record.diarizationSegments = #"[{"oops": 1}]"#
            record.transcriptSegments = "{not json"
        }
        let collector = SummaryCollector()
        let stream = store.observeSummaries(limit: nil)
        let observation = Task {
            for await list in stream {
                await collector.append(list)
            }
        }
        defer { observation.cancel() }

        let listed = try await store.fetchSummaries(limit: nil)

        XCTAssertEqual(listed.map(\.id), [broken.id, good.id], "the list reads none of those columns")
        XCTAssertEqual(listed.first?.displayTitle, "Hello world")
        XCTAssertEqual(listed.first?.speakerCount, 2, "the row's own columns still read")
        try await waitUntil { await collector.latest != nil }
        let observed = await collector.latest
        XCTAssertEqual(observed?.map(\.id), [broken.id, good.id], "the observed list reads none of them either")
        do {
            _ = try await store.fetch(id: broken.id)
            XCTFail("opening the item still reports what cannot be read")
        } catch {}
    }

    func testAPDFWhosePagesCannotBeReadIsListedWithoutCounts() async throws {
        let handout = pdf(minute: 1)
        try await insert([handout])
        try await tamper(handout.id) { record in record.documentPages = "{not json" }

        let listed = try await store.fetchSummaries(limit: nil)

        XCTAssertEqual(listed.map(\.id), [handout.id])
        XCTAssertEqual(listed.first?.documentPageCount, 0)
        XCTAssertEqual(listed.first?.ocrPageCount, 0)
        XCTAssertEqual(listed.first?.textWordCount, 0, "a PDF's text is not read for its row")
    }

    func testUnknownValuesReadAsTheSameFallbacksAsAFullRead() async throws {
        let row = wordDocument(minute: 1)
        try await insert([row])
        try await tamper(row.id) { record in
            record.sourceType = "hologram"
            record.status = "summarizing"
            record.privacyClass = "restricted"
            record.documentFormat = "odt"
        }

        let listed = try await store.fetchSummaries(limit: nil)
        let full = try await store.fetch(id: row.id)

        let summary = try XCTUnwrap(listed.first)
        XCTAssertEqual(summary.sourceType, .file)
        XCTAssertEqual(summary.status, .interrupted)
        XCTAssertEqual(summary.privacyClass, .clinical)
        XCTAssertNil(summary.documentFormat)
        XCTAssertEqual(summary, full.map(TranscriptionSummary.init))
    }

    func testARowWhoseOwnColumnsCannotBeReadIsSkippedAndTheRestListed() async throws {
        let good = meeting("Good", minute: 1)
        let broken = meeting("Broken", minute: 2)
        try await insert([good, broken])
        try await database.writer.write { db in
            try db.execute(sql: "UPDATE transcriptions SET createdAt = 'not a date' WHERE fileName = 'Broken.m4a'")
        }

        let listed = try await store.fetchSummaries(limit: nil)

        XCTAssertEqual(listed.map(\.id), [good.id], "one unreadable row never empties the list")
    }

    // MARK: - Observation

    func testTheObservedListFollowsWhatRowsShowAndIgnoresNotesAndTimings() async throws {
        let region = try await database.writer.read { db in try TranscriptionListingQueries.observedRegion(db) }
        func reacts(to columns: Set<String>) -> Bool {
            region.isModified(byEventsOfKind: .update(tableName: "transcriptions", columnNames: columns))
        }

        XCTAssertFalse(reacts(to: ["userNotes", "updatedAt"]), "a notes keystroke never re-reads the list")
        XCTAssertFalse(reacts(to: ["wordTimestamps", "diarizationSegments", "updatedAt"]))
        XCTAssertTrue(reacts(to: ["isFavorite", "updatedAt"]))
        XCTAssertTrue(reacts(to: ["status", "errorMessage", "updatedAt"]))
        XCTAssertTrue(reacts(to: ["titleOverride", "updatedAt"]))
        XCTAssertTrue(reacts(to: ["privacyClass", "updatedAt"]))
        XCTAssertTrue(reacts(to: ["mediaRelativePath", "audioRemovedAt", "updatedAt"]))
        XCTAssertTrue(
            reacts(to: ["speakers", "transcriptSegments", "updatedAt"]), "a rename changes what a search finds")
        XCTAssertTrue(region.isModified(byEventsOfKind: .insert(tableName: "transcriptions")))
        XCTAssertTrue(region.isModified(byEventsOfKind: .delete(tableName: "transcriptions")))
    }

    func testObserveSummariesFollowsInsertsAndOneFieldWrites() async throws {
        let collector = SummaryCollector()
        let stream = store.observeSummaries(limit: 2)
        let observation = Task {
            for await list in stream {
                await collector.append(list)
            }
        }
        defer { observation.cancel() }
        try await waitUntil { await collector.latest != nil }

        let first = meeting("First", minute: 1)
        let second = meeting("Second", minute: 2)
        let third = meeting("Third", minute: 3)
        try await insert([first, second, third])
        try await waitUntil { await collector.latest?.map(\.id) == [third.id, second.id] }

        _ = try await store.updateFavorite(id: third.id, isFavorite: true)
        try await waitUntil { await collector.latest?.first?.isFavorite == true }
        try await store.delete(id: third.id)
        try await waitUntil { await collector.latest?.map(\.id) == [second.id, first.id] }
    }

    // MARK: - Search (the Library's rule, in the store)

    func testSearchFindsTitleTextFileNameAndSpeakerLabelsLikeTheSharedRule() async throws {
        var renamed = meeting("Ward round", minute: 1)
        renamed.titleOverride = "Quarterly BUDGET review"
        renamed.derivedTitle = "Hidden derived title"
        var spoken = meeting("Voice note", minute: 2)
        spoken.rawTranscript = "remember the budget spreadsheet"
        spoken.speakers = [SpeakerInfo(id: "S1", label: "Dr. Synthetic")]
        let cleaned = textItem(minute: 3)
        var accented = wordDocument(minute: 4)
        accented.rawTranscript = "Café con José"
        var unreadableSpeakers = meeting("Clinic", minute: 5)
        unreadableSpeakers.rawTranscript = "the clinic budget"
        let rows = [renamed, spoken, cleaned, accented, unreadableSpeakers]
        try await insert(rows)
        try await tamper(unreadableSpeakers.id) { record in record.speakers = "{not json" }

        func found(_ query: String) async throws -> Set<UUID> {
            try await store.searchTranscriptions(matching: query)
        }

        let budget = try await found("  bUdGeT ")
        XCTAssertEqual(budget, [renamed.id, spoken.id, unreadableSpeakers.id])
        let ward = try await found("ward round")
        XCTAssertEqual(ward, [renamed.id], "the file name")
        let hidden = try await found("hidden derived")
        XCTAssertEqual(hidden, [], "a derived title the rename hides is not the title")
        let doctor = try await found("dr. synthetic")
        XCTAssertEqual(doctor, [spoken.id], "a speaker's label")
        let clean = try await found("xarelto")
        XCTAssertEqual(clean, [cleaned.id], "the text as shown (clean)")
        let raw = try await found("zarelto")
        XCTAssertEqual(raw, [], "not the raw words the clean text replaced")
        let accent = try await found("JOSÉ")
        XCTAssertEqual(accent, [accented.id])
        let empty = try await found("   ")
        XCTAssertEqual(empty, [])
        for query in ["budget", "speaker 1", "synthetic", "dose", "handout", "café"] {
            let fromStore = try await found(query)
            let readable = rows.filter { $0.id != unreadableSpeakers.id }
            var expected = Set(readable.filter { $0.matchesSearch(query) }.map(\.id))
            // Its speakers cannot be read, so only its title, text and file name can match.
            let withoutLabels = TranscriptionSearch.matches(
                query: query, displayTitle: unreadableSpeakers.displayTitle,
                displayText: unreadableSpeakers.displayText, fileName: unreadableSpeakers.fileName,
                speakerLabels: { [] })
            if withoutLabels { expected.insert(unreadableSpeakers.id) }
            XCTAssertEqual(fromStore, expected, "the same rule as a full row's matchesSearch: \(query)")
        }
    }

    // MARK: - Helpers

    /// Rewrites the stored row's raw columns, bypassing `Transcription`, as a newer build or a damaged file would.
    private func tamper(_ id: UUID, _ change: @escaping @Sendable (inout TranscriptionRecord) -> Void) async throws {
        try await database.writer.write { db in
            guard var record = try TranscriptionRecord.fetchOne(db, key: id) else { throw SummaryTestError.missing }
            change(&record)
            try record.update(db)
        }
    }

    /// Polls `condition` until it holds (instead of a fixed sleep); throws after `timeout`.
    private func waitUntil(timeout: TimeInterval = 5, _ condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        if await condition() { return }
        throw SummaryTestError.timeout
    }
}

private actor SummaryCollector {
    private(set) var latest: [TranscriptionSummary]?

    func append(_ list: [TranscriptionSummary]) {
        latest = list
    }
}

private enum SummaryTestError: Error {
    case missing, timeout
}
