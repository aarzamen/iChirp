import ChirpCore
import GRDB
import XCTest

@testable import ChirpStore

/// Plan 023 (UX audit F43): `GRDBDeliverableStore`'s `DeliverableListing`, the Library's read-only lists of documents.
final class DeliverableListingStoreTests: XCTestCase {
    private var database: DatabaseManager!
    private var store: GRDBDeliverableStore!
    private var transcripts: GRDBTranscriptionStore!
    /// A fixed base so every document's time is distinct and ordered.
    private let base = Date(timeIntervalSince1970: 1_790_000_000)

    override func setUp() async throws {
        database = try DatabaseManager.inMemory()
        store = GRDBDeliverableStore(database: database)
        transcripts = GRDBTranscriptionStore(database: database)
    }

    private func insertTranscript(_ title: String = "Synthetic", privacy: PrivacyClass = .personal) async throws
        -> Transcription
    {
        var row = Transcription(fileName: "\(title).m4a", status: .completed, privacyClass: privacy)
        row.rawTranscript = "Synthetic transcript about the blue heron."
        try await transcripts.insert(row)
        return row
    }

    private func document(
        _ title: String,
        from transcript: Transcription,
        secondsAfterBase: Double,
        text: String = "Generated summary.",
        privacy: PrivacyClass = .personal
    ) -> Deliverable {
        let created = base.addingTimeInterval(secondsAfterBase)
        return Deliverable(
            transcriptionID: transcript.id, promptID: nil, promptVersionID: nil, title: title,
            engineID: "apple.foundation-models", provider: "Apple on-device model", model: nil, locality: .onDevice,
            text: text, privacyClass: privacy, createdAt: created)
    }

    // MARK: - Summaries

    func testSummariesListEveryDocumentNewestFirstWithoutACap() async throws {
        var expected: [Deliverable] = []
        for index in 0..<8 {
            let transcript = try await insertTranscript("Source \(index)")
            for number in 0..<20 {
                let made = document(
                    number.isMultiple(of: 4) ? "SOAP note" : "Summary", from: transcript,
                    secondsAfterBase: Double(index * 100 + number))
                try await store.insertDeliverable(made)
                expected.append(made)
            }
        }

        let summaries = try await store.fetchDeliverableSummaries()

        XCTAssertEqual(summaries.count, 160, "no 50-item cap: every document is listed")
        XCTAssertEqual(
            summaries.map(\.id), expected.sorted { $0.createdAt > $1.createdAt }.map(\.id), "newest first")
        let soap = try XCTUnwrap(summaries.first { $0.title == "SOAP note" })
        let original = try XCTUnwrap(expected.first { $0.id == soap.id })
        XCTAssertEqual(soap.transcriptionID, original.transcriptionID)
        XCTAssertEqual(soap.provider, "Apple on-device model")
        XCTAssertEqual(soap.locality, .onDevice)
        XCTAssertEqual(soap.privacyClass, .personal)
    }

    func testSummaryKeepsOnlyAFoldedStartOfTheText() async throws {
        let transcript = try await insertTranscript()
        let long =
            "## Subjective\n- **Patient** reports   a synthetic cough.\n> quoted `line`\n"
            + String(repeating: "More synthetic words. ", count: 200)
        try await store.insertDeliverable(document("SOAP note", from: transcript, secondsAfterBase: 1, text: long))

        let first = try await store.fetchDeliverableSummaries().first
        let summary = try XCTUnwrap(first)

        XCTAssertTrue(
            summary.snippet.hasPrefix("Subjective Patient reports a synthetic cough. quoted line More synthetic"),
            summary.snippet)
        XCTAssertLessThanOrEqual(summary.snippet.count, DeliverableSummary.textStartLength)
        XCTAssertFalse(summary.snippet.contains("\n"))
    }

    func testUnknownStoredClassReadsClinical() async throws {
        let transcript = try await insertTranscript()
        let made = document("Summary", from: transcript, secondsAfterBase: 1, privacy: .general)
        try await store.insertDeliverable(made)
        try await database.writer.write { db in
            guard var record = try DeliverableRecord.fetchOne(db, key: made.id) else { return XCTFail("missing") }
            record.privacyClass = "secret-future-class"
            record.locality = "orbit"
            try record.update(db)
        }

        let first = try await store.fetchDeliverableSummaries().first
        let summary = try XCTUnwrap(first)
        XCTAssertEqual(summary.privacyClass, .clinical)
        XCTAssertEqual(summary.locality, .cloud)
    }

    func testAnUnreadableRowIsSkippedNotTheWholeList() async throws {
        let transcript = try await insertTranscript()
        let good = document("Summary", from: transcript, secondsAfterBase: 1)
        try await store.insertDeliverable(good)
        try await database.writer.write { db in
            try db.execute(
                sql: """
                    INSERT INTO deliverables (id, transcriptionId, title, engineId, provider, locality, text,
                        privacyClass, createdAt, updatedAt)
                    VALUES (?, ?, 'Summary', 'x', 'x', 'onDevice', 'text', 'personal', 'not a date', 'not a date')
                    """,
                arguments: [UUID(), transcript.id])
        }

        let summaries = try await store.fetchDeliverableSummaries()
        XCTAssertEqual(summaries.map(\.id), [good.id])
    }

    // MARK: - Observation

    func testObservationFollowsInsertEditDeleteAndTheTranscriptCascade() async throws {
        let visit = try await insertTranscript("Visit")
        let kept = try await insertTranscript("Kept")
        let collector = SummaryCollector()
        let store = try XCTUnwrap(self.store)
        let observation = Task {
            for await value in store.observeDeliverableSummaries() {
                await collector.append(value)
            }
        }
        defer { observation.cancel() }
        try await waitUntil { await collector.latest?.isEmpty == true }

        let soap = document("SOAP note", from: visit, secondsAfterBase: 1, text: "Synthetic plan.")
        let summary = document("Summary", from: kept, secondsAfterBase: 2)
        try await store.insertDeliverable(soap)
        try await store.insertDeliverable(summary)
        try await waitUntil { await collector.latest?.map(\.id) == [summary.id, soap.id] }

        _ = try await store.updateDeliverableText(id: soap.id, text: "Edited synthetic plan.")
        try await waitUntil { await collector.latest?.first { $0.id == soap.id }?.snippet == "Edited synthetic plan." }

        _ = try await store.raiseDeliverablePrivacyClass(transcriptionID: visit.id, to: .clinical)
        try await waitUntil { await collector.latest?.first { $0.id == soap.id }?.privacyClass == .clinical }

        try await transcripts.delete(id: visit.id)  // the foreign key deletes its documents
        try await waitUntil { await collector.latest?.map(\.id) == [summary.id] }

        try await store.deleteDeliverable(id: summary.id)
        try await waitUntil { await collector.latest?.isEmpty == true }
    }

    // MARK: - Search

    func testSearchMatchesTitleAndTextIgnoringCase() async throws {
        let transcript = try await insertTranscript()
        let soap = document(
            "SOAP note", from: transcript, secondsAfterBase: 1, text: "Start Metoprolol 25 mg; recheck in 50% of cases."
        )
        let summary = document("Summary", from: transcript, secondsAfterBase: 2, text: "A synthetic summary.")
        let accented = document("Summary", from: transcript, secondsAfterBase: 3, text: "Seen with JOSÉ and Zoë.")
        for made in [soap, summary, accented] { try await store.insertDeliverable(made) }

        let metoprolol = try await store.searchDeliverables(matching: "  mEtOpRoLoL ")
        XCTAssertEqual(metoprolol, [soap.id])
        let byTitle = try await store.searchDeliverables(matching: "soap")
        XCTAssertEqual(byTitle, [soap.id])
        let summaries = try await store.searchDeliverables(matching: "summary")
        XCTAssertEqual(summaries, [summary.id, accented.id], "title “Summary” and the text “synthetic summary”")
        let percent = try await store.searchDeliverables(matching: "50%")
        XCTAssertEqual(percent, [soap.id], "a literal “%” matches itself")
        let percentWildcard = try await store.searchDeliverables(matching: "5%g")
        XCTAssertEqual(percentWildcard, [], "“%” is not a wildcard (it would match “25 mg”)")
        let underscoreWildcard = try await store.searchDeliverables(matching: "5_mg")
        XCTAssertEqual(underscoreWildcard, [], "“_” is not a wildcard (it would match “5 mg”)")
        let accentedMatch = try await store.searchDeliverables(matching: "josé")
        XCTAssertEqual(accentedMatch, [accented.id], "a non-ASCII query ignores case too")
        let empty = try await store.searchDeliverables(matching: "   ")
        XCTAssertEqual(empty, [])
        let none = try await store.searchDeliverables(matching: "heron")
        XCTAssertEqual(none, [], "the transcript's text is not the document's")
    }

    // MARK: - Performance

    /// Thousands of documents: the Library's list read and a text search stay far below a frame budget's worth of
    /// work per keystroke on the Mac (budgets are generous for a debug build; measured times are printed).
    func testThousandsOfDocumentsListAndSearchQuickly() async throws {
        let transcriptCount = 1_000
        let perTranscript = 5
        let body = String(repeating: "Synthetic assessment and plan with ordinary words. ", count: 60)  // ~3 KB
        let sources = (0..<transcriptCount).map { index in
            var row = Transcription(fileName: "Source \(index).m4a", status: .completed)
            row.createdAt = base.addingTimeInterval(Double(index * 10))
            return row
        }
        let needleID = UUID()
        try await database.writer.write { [base] db in
            for row in sources {
                try TranscriptionRecord(row).insert(db)
            }
            for (index, row) in sources.enumerated() {
                for number in 0..<perTranscript {
                    let isNeedle = index == 777 && number == 3
                    let made = Deliverable(
                        id: isNeedle ? needleID : UUID(), transcriptionID: row.id, promptID: nil, promptVersionID: nil,
                        title: number == 0 ? "SOAP note" : "Summary", engineID: "x", provider: "x", model: nil,
                        locality: .onDevice, text: isNeedle ? body + "Zanubrutinib." : body,
                        privacyClass: .personal,
                        createdAt: base.addingTimeInterval(Double(index * 10 + number + 1)))
                    try DeliverableRecord(made).insert(db)
                }
            }
        }
        let clock = ContinuousClock()

        var mark = clock.now
        let summaries = try await store.fetchDeliverableSummaries()
        let listTime = (clock.now - mark).seconds
        XCTAssertEqual(summaries.count, transcriptCount * perTranscript)

        mark = clock.now
        let found = try await store.searchDeliverables(matching: "zanubrutinib")
        let searchTime = (clock.now - mark).seconds
        XCTAssertEqual(found, [needleID])

        print(
            String(
                format: "document_listing_perf documents=%d list=%.3fs search=%.3fs", summaries.count, listTime,
                searchTime))
        XCTAssertLessThan(listTime, 3, "5,000 summaries")
        XCTAssertLessThan(searchTime, 3, "a search over ~15 MB of document text")
    }
}

// MARK: - Test helpers

private actor SummaryCollector {
    private(set) var values: [[DeliverableSummary]] = []

    var latest: [DeliverableSummary]? { values.last }

    func append(_ value: [DeliverableSummary]) {
        values.append(value)
    }
}

private struct ListingTimeoutError: Error {}

/// Polls `condition` until it holds, instead of a fixed sleep; throws after `timeout`.
private func waitUntil(timeout: TimeInterval = 3, condition: () async -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return }
        try await Task.sleep(nanoseconds: 20_000_000)
    }
    if await condition() { return }
    throw ListingTimeoutError()
}

extension Duration {
    fileprivate var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
