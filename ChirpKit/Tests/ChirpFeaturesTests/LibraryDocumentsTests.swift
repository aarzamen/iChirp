import ChirpCore
import Foundation
import XCTest

@testable import ChirpFeatures

/// In-memory `DeliverableListing` with `GRDBDeliverableStore`'s rules: newest first, every change published to the
/// observers, text search ignoring case.
actor FakeDeliverableListing: DeliverableListing {
    private var documents: [UUID: (summary: DeliverableSummary, text: String)] = [:]
    private var observers: [UUID: AsyncStream<[DeliverableSummary]>.Continuation] = [:]
    private var searchError: FakeError?
    private(set) var searchCalls = 0

    init(_ documents: [(summary: DeliverableSummary, text: String)] = []) {
        for document in documents {
            self.documents[document.summary.id] = document
        }
    }

    func fetchDeliverableSummaries() async throws -> [DeliverableSummary] {
        sorted()
    }

    nonisolated func observeDeliverableSummaries() -> AsyncStream<[DeliverableSummary]> {
        let (stream, continuation) = AsyncStream.makeStream(of: [DeliverableSummary].self)
        let token = UUID()
        continuation.onTermination = { _ in
            Task { await self.removeObserver(token) }
        }
        Task { await self.addObserver(token, continuation) }
        return stream
    }

    func searchDeliverables(matching query: String) async throws -> Set<UUID> {
        searchCalls += 1
        if let searchError { throw searchError }
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        return Set(
            documents.values.filter {
                $0.summary.title.localizedCaseInsensitiveContains(needle)
                    || $0.text.localizedCaseInsensitiveContains(needle)
            }.map(\.summary.id))
    }

    // MARK: Test helpers

    func insert(_ summary: DeliverableSummary, text: String) {
        documents[summary.id] = (summary, text)
        publish()
    }

    /// What the database's cascade does when a transcript is deleted.
    func deleteDocuments(of transcriptionID: UUID) {
        documents = documents.filter { $0.value.summary.transcriptionID != transcriptionID }
        publish()
    }

    func failSearch(with error: FakeError?) {
        searchError = error
    }

    private func addObserver(_ token: UUID, _ continuation: AsyncStream<[DeliverableSummary]>.Continuation) {
        observers[token] = continuation
        continuation.yield(sorted())
    }

    private func removeObserver(_ token: UUID) {
        observers[token] = nil
    }

    private func publish() {
        let snapshot = sorted()
        for continuation in observers.values {
            continuation.yield(snapshot)
        }
    }

    private func sorted() -> [DeliverableSummary] {
        documents.values.map(\.summary).sorted {
            $0.createdAt != $1.createdAt ? $0.createdAt > $1.createdAt : $0.id.uuidString < $1.id.uuidString
        }
    }
}

/// Plan 023 (UX audit F43): generated documents in the Library, the Documents filter, search over their text, the
/// "Made from this" lists, and paging that reaches every row.
@MainActor
final class LibraryDocumentsTests: XCTestCase {
    /// 2026-09-22 15:00 UTC.
    private let now = Date(timeIntervalSince1970: 1_790_089_200)

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = Locale(identifier: "en_US")
        return calendar
    }

    private func source(
        _ title: String,
        _ sourceType: Transcription.SourceType = .dictation,
        minutesAgo: Int,
        text: String = "",
        privacy: PrivacyClass = .personal
    ) -> Transcription {
        var row = Transcription(
            createdAt: now.addingTimeInterval(-Double(minutesAgo * 60)),
            sourceType: sourceType,
            fileName: "\(title).m4a",
            status: .completed,
            privacyClass: privacy)
        row.titleOverride = title
        row.rawTranscript = text
        return row
    }

    private func document(
        _ template: String,
        from source: Transcription,
        minutesAgo: Int,
        privacy: PrivacyClass = .personal,
        text: String = "Synthetic document text."
    ) -> (summary: DeliverableSummary, text: String) {
        let created = now.addingTimeInterval(-Double(minutesAgo * 60))
        let summary = DeliverableSummary(
            id: UUID(), transcriptionID: source.id, promptID: nil, title: template, privacyClass: privacy,
            provider: "Apple on-device model", locality: .onDevice, createdAt: created, updatedAt: created,
            editedAt: nil, textStart: text)
        return (summary, text)
    }

    private func makeViewModel(
        rows: [Transcription],
        documents: [(summary: DeliverableSummary, text: String)],
        pageSize: Int = 100
    ) async -> (LibraryViewModel, FakeStore, FakeDeliverableListing) {
        let store = FakeStore(rows: rows)
        let listing = FakeDeliverableListing(documents)
        let fixedNow = now
        let viewModel = LibraryViewModel(
            store: store, paths: AppPaths(root: FileManager.default.temporaryDirectory), documents: listing,
            pageSize: pageSize, searchDebounce: .zero, calendar: calendar, now: { fixedNow })
        await viewModel.start()
        addTeardownBlock { @MainActor in viewModel.stop() }
        return (viewModel, store, listing)
    }

    /// Every entry id the shown sections hold, paging with `showMore()` until nothing is left.
    private func pageThroughEverything(_ viewModel: LibraryViewModel) -> [LibraryEntry.ID] {
        var pages = 0
        while viewModel.hasMore {
            viewModel.showMore()
            pages += 1
            if pages > 10_000 {
                XCTFail("paging never ends")
                break
            }
        }
        return viewModel.sections.flatMap(\.entries).map(\.id)
    }

    /// 12 sources of every kind, 150 documents across them (more than the old 50-item cap and several pages).
    private func largeFixture() -> (rows: [Transcription], documents: [(summary: DeliverableSummary, text: String)]) {
        let kinds: [Transcription.SourceType] = [.dictation, .meeting, .file, .url, .podcast, .document, .text]
        var rows: [Transcription] = []
        var documents: [(summary: DeliverableSummary, text: String)] = []
        var minute = 0
        for index in 0..<12 {
            minute += 7
            let row = source("Source \(index)", kinds[index % kinds.count], minutesAgo: 10_000 - minute * 10)
            rows.append(row)
            for number in 0..<(index < 6 ? 15 : 10) {
                documents.append(
                    document(
                        number.isMultiple(of: 3) ? "SOAP note" : "Summary", from: row,
                        minutesAgo: 10_000 - minute * 10 - number - 1))
            }
        }
        return (rows, documents)
    }

    // MARK: - Reachability

    func testEveryDocumentIsReachableFromTheLibrary() async {
        let fixture = largeFixture()
        XCTAssertGreaterThan(fixture.documents.count, 100)
        let (viewModel, _, _) = await makeViewModel(rows: fixture.rows, documents: fixture.documents, pageSize: 20)

        XCTAssertTrue(viewModel.hasMore, "a page shows 20 rows; the rest are one showMore() away")
        let all = pageThroughEverything(viewModel)
        XCTAssertEqual(all.count, fixture.rows.count + fixture.documents.count)
        XCTAssertEqual(Set(all).count, all.count, "no row twice")
        XCTAssertEqual(
            Set(all.compactMap { if case .document(let id) = $0 { id } else { nil } }),
            Set(fixture.documents.map(\.summary.id)))
        XCTAssertEqual(
            Set(all.compactMap { if case .item(let id) = $0 { id } else { nil } }), Set(fixture.rows.map(\.id)))

        viewModel.filter = .documents
        XCTAssertEqual(viewModel.sections.flatMap(\.entries).count, 20, "a new filter starts at the first page")
        let documentsOnly = pageThroughEverything(viewModel)
        let newestFirst = fixture.documents.sorted { $0.summary.createdAt > $1.summary.createdAt }
        XCTAssertEqual(documentsOnly, newestFirst.map { LibraryEntry.ID.document($0.summary.id) })
    }

    func testEntriesAreNewestFirstAcrossItemsAndDocuments() async {
        let visit = source("Visit", minutesAgo: 60)
        let memo = source("Memo", minutesAgo: 30)
        let soap = document("SOAP note", from: visit, minutesAgo: 45)
        let summary = document("Summary", from: memo, minutesAgo: 10)
        let (viewModel, _, _) = await makeViewModel(rows: [visit, memo], documents: [soap, summary])

        XCTAssertEqual(
            viewModel.visibleEntries.map(\.id),
            [.document(summary.summary.id), .item(memo.id), .document(soap.summary.id), .item(visit.id)])
        XCTAssertEqual(viewModel.sections.map(\.title), ["Today"])
    }

    // MARK: - The Documents filter

    func testDocumentsFilterIncludesExactlyTheDocuments() async {
        let fixture = largeFixture()
        let (viewModel, _, _) = await makeViewModel(rows: fixture.rows, documents: fixture.documents, pageSize: 1_000)

        viewModel.filter = .documents
        XCTAssertEqual(Set(viewModel.visibleDocuments.map(\.id)), Set(fixture.documents.map(\.summary.id)))
        XCTAssertTrue(viewModel.visibleItems.isEmpty, "Documents lists no recording, text item or imported file")
        XCTAssertEqual(viewModel.visibleEntries.count, fixture.documents.count)

        for filter in LibraryViewModel.Filter.allCases where filter != .all && filter != .documents {
            viewModel.filter = filter
            XCTAssertTrue(viewModel.visibleDocuments.isEmpty, "\(filter) lists sources only")
            XCTAssertFalse(viewModel.visibleItems.isEmpty, "\(filter) keeps its sources")
        }

        viewModel.filter = .all
        XCTAssertEqual(viewModel.visibleEntries.count, fixture.rows.count + fixture.documents.count)
    }

    func testExistingFiltersKeepTheirNamesAndOrderWithDocumentsLast() {
        XCTAssertEqual(
            LibraryViewModel.Filter.allCases.map(\.title),
            ["All", "Meetings", "Dictations", "Video", "Local", "Documents"])
    }

    // MARK: - Search

    func testSearchFindsDocumentText() async {
        let visit = source("Clinic visit", minutesAgo: 60, text: "follow up in two weeks")
        let soap = document(
            "SOAP note", from: visit, minutesAgo: 50, privacy: .clinical,
            text: "## Plan\nStart **metoprolol** 25 mg twice daily.")
        let summary = document("Summary", from: visit, minutesAgo: 40, text: "A short synthetic summary.")
        let (viewModel, _, listing) = await makeViewModel(rows: [visit], documents: [soap, summary])

        viewModel.searchText = "METOPROLOL"
        await viewModel.searchSettled()
        XCTAssertEqual(viewModel.visibleEntries.map(\.id), [.document(soap.summary.id)])
        let calls = await listing.searchCalls
        XCTAssertGreaterThan(calls, 0, "document text is searched in the store")

        viewModel.searchText = "soap"  // the template name
        await viewModel.searchSettled()
        XCTAssertEqual(viewModel.visibleEntries.map(\.id), [.document(soap.summary.id)])

        viewModel.searchText = "clinic visit"  // the source's title finds it and what was made from it
        await viewModel.searchSettled()
        XCTAssertEqual(
            Set(viewModel.visibleEntries.map(\.id)),
            [.item(visit.id), .document(soap.summary.id), .document(summary.summary.id)])

        viewModel.filter = .documents
        XCTAssertEqual(
            Set(viewModel.visibleEntries.map(\.id)), [.document(soap.summary.id), .document(summary.summary.id)])

        viewModel.searchText = ""
        await viewModel.searchSettled()
        XCTAssertEqual(viewModel.visibleEntries.count, 2)
        viewModel.filter = .all
        XCTAssertEqual(viewModel.visibleEntries.count, 3)
    }

    func testSearchSeesDocumentsAddedWhileItIsActive() async {
        let visit = source("Visit", minutesAgo: 60)
        let (viewModel, _, listing) = await makeViewModel(rows: [visit], documents: [])
        viewModel.searchText = "warfarin"
        await viewModel.searchSettled()
        XCTAssertTrue(viewModel.visibleEntries.isEmpty)

        let soap = document("SOAP note", from: visit, minutesAgo: 1, text: "Hold warfarin for two days.")
        await listing.insert(soap.summary, text: soap.text)
        await waitUntil { viewModel.visibleEntries.map(\.id) == [.document(soap.summary.id)] }
    }

    func testFailedDocumentSearchSaysSoAndStillMatchesTitles() async {
        let visit = source("Visit", minutesAgo: 60)
        let soap = document("SOAP note", from: visit, minutesAgo: 30, text: "Aspirin daily.")
        let (viewModel, _, listing) = await makeViewModel(rows: [visit], documents: [soap])
        await listing.failSearch(with: FakeError(message: "database is locked"))

        viewModel.searchText = "soap"
        await viewModel.searchSettled()
        XCTAssertEqual(viewModel.visibleEntries.map(\.id), [.document(soap.summary.id)])
        XCTAssertEqual(viewModel.searchError, "database is locked")

        viewModel.searchText = ""
        await viewModel.searchSettled()
        XCTAssertNil(viewModel.searchError)
    }

    // MARK: - Made from this

    func testMadeFromThisListsASourcesDocumentsNewestFirst() async {
        let visit = source("Visit", minutesAgo: 120)
        let other = source("Other", minutesAgo: 100)
        let first = document("Summary", from: visit, minutesAgo: 90)
        let second = document("SOAP note", from: visit, minutesAgo: 60)
        let third = document("Action items", from: visit, minutesAgo: 30)
        let unrelated = document("Summary", from: other, minutesAgo: 45)
        let (viewModel, _, listing) = await makeViewModel(
            rows: [visit, other], documents: [second, unrelated, first, third])

        XCTAssertEqual(
            viewModel.documents(madeFrom: visit.id).map(\.id),
            [third.summary.id, second.summary.id, first.summary.id])
        XCTAssertEqual(viewModel.documents(madeFrom: other.id).map(\.id), [unrelated.summary.id])
        XCTAssertTrue(viewModel.documents(madeFrom: UUID()).isEmpty)

        let newest = document("Agenda", from: visit, minutesAgo: 1)
        await listing.insert(newest.summary, text: newest.text)
        await waitUntil { viewModel.documents(madeFrom: visit.id).first?.id == newest.summary.id }
        XCTAssertEqual(viewModel.documents(madeFrom: visit.id).count, 4)
    }

    // MARK: - Rows

    func testDocumentRowCarriesTypeSourceAndEffectiveClass() async {
        let visit = source("Visit 12", minutesAgo: 60, privacy: .personal)
        let soap = document("SOAP note", from: visit, minutesAgo: 50, privacy: .clinical)
        let summary = document("Summary", from: visit, minutesAgo: 40, privacy: .personal)
        let general = source("Lecture", .file, minutesAgo: 30, privacy: .general)
        let notes = document("Meeting notes", from: general, minutesAgo: 20, privacy: .general)
        let orphanSource = source("Unreadable", minutesAgo: 10)
        let orphan = document("Summary", from: orphanSource, minutesAgo: 5, privacy: .general)
        let (viewModel, _, _) = await makeViewModel(rows: [visit, general], documents: [soap, summary, notes, orphan])

        let byID = Dictionary(uniqueKeysWithValues: viewModel.documents.map { ($0.id, $0) })
        XCTAssertEqual(byID[soap.summary.id]?.typeTitle, "SOAP note")
        XCTAssertEqual(byID[soap.summary.id]?.sourceTitle, "Visit 12")
        XCTAssertEqual(byID[soap.summary.id]?.sourceType, .dictation)
        XCTAssertEqual(byID[soap.summary.id]?.effectivePrivacyClass, .clinical)
        XCTAssertEqual(
            byID[summary.summary.id]?.effectivePrivacyClass, .clinical,
            "a personal summary of a source with a clinical SOAP note is treated as clinical (EffectivePrivacyClass)")
        XCTAssertEqual(byID[notes.summary.id]?.effectivePrivacyClass, .general)
        XCTAssertNil(byID[orphan.summary.id]?.sourceTitle, "its source is not in the Library")
        XCTAssertEqual(byID[orphan.summary.id]?.effectivePrivacyClass, .clinical, "an unknown source reads clinical")
        XCTAssertNotNil(
            viewModel.visibleEntries.first { $0.id == .document(orphan.summary.id) },
            "a document whose source cannot be read is still listed")
    }

    func testDeletingASourceTakesItsDocumentsOffTheList() async throws {
        let visit = source("Visit", minutesAgo: 60)
        let kept = source("Kept", minutesAgo: 30)
        let soap = document("SOAP note", from: visit, minutesAgo: 50)
        let summary = document("Summary", from: kept, minutesAgo: 20)
        let (viewModel, _, listing) = await makeViewModel(rows: [visit, kept], documents: [soap, summary])

        try await viewModel.delete(visit.id)
        await listing.deleteDocuments(of: visit.id)  // the database cascade

        // Observed lists converge (a snapshot queued before the delete may land first), then stay without them.
        await waitUntil { viewModel.documents(madeFrom: visit.id).isEmpty }
        await waitUntil {
            viewModel.visibleEntries.map(\.id) == [.document(summary.summary.id), .item(kept.id)]
        }
    }

    func testSectionsOfAnotherYearNameTheYear() async {
        let lastYear = source("Old", minutesAgo: 60 * 24 * 370)
        let (viewModel, _, _) = await makeViewModel(rows: [lastYear], documents: [])
        XCTAssertEqual(viewModel.sections.map(\.title), ["Sep 17, 2025"])
    }

    // MARK: - Performance

    /// A Library of thousands of rows stays smooth: the main-actor work (join, filter, merge, a page of sections) is
    /// linear and small, a page never grows with the Library, and search runs off the main actor. The budgets are
    /// generous (debug build, a busy Mac) so the test catches a quadratic step, not a slow machine; the measured times
    /// are printed.
    func testThousandsOfRowsStayWithinBudget() async {
        let sourceCount = 2_000
        let documentsPerSource = 3
        var rows: [Transcription] = []
        var documents: [(summary: DeliverableSummary, text: String)] = []
        for index in 0..<sourceCount {
            let row = source(
                "Source \(index)", index.isMultiple(of: 2) ? .dictation : .meeting, minutesAgo: index * 30 + 10,
                text: String(repeating: "synthetic words about the heron ", count: 40))
            rows.append(row)
            for number in 0..<documentsPerSource {
                documents.append(
                    document(
                        number == 0 ? "SOAP note" : "Summary", from: row, minutesAgo: index * 30 + 9 - number,
                        privacy: number == 0 ? .clinical : .personal,
                        text: "Plan for source \(index): synthetic note \(number)."))
            }
        }
        let clock = ContinuousClock()
        let store = FakeStore(rows: rows)
        let listing = FakeDeliverableListing(documents)
        let fixedNow = now
        let large = LibraryViewModel(
            store: store, paths: AppPaths(root: FileManager.default.temporaryDirectory), documents: listing,
            searchDebounce: .zero, calendar: calendar, now: { fixedNow })
        addTeardownBlock { @MainActor in large.stop() }

        var mark = clock.now
        await large.start()
        let startTime = (clock.now - mark).seconds
        XCTAssertEqual(large.visibleEntries.count, sourceCount * (1 + documentsPerSource))
        XCTAssertEqual(large.sections.flatMap(\.entries).count, large.pageSize, "only the first page is laid out")

        mark = clock.now
        large.filter = .documents
        large.filter = .meetings
        large.filter = .all
        let filterTime = (clock.now - mark).seconds / 3

        mark = clock.now
        large.showMore()
        let pageTime = (clock.now - mark).seconds
        XCTAssertEqual(large.sections.flatMap(\.entries).count, large.pageSize * 2)

        mark = clock.now
        large.searchText = "source 1999"
        await large.searchSettled()
        let searchTime = (clock.now - mark).seconds
        XCTAssertEqual(
            Set(large.visibleEntries.map(\.id)).count, 1 + documentsPerSource,
            "the source titled “Source 1999” and the three documents made from it")

        print(
            String(
                format: "library_perf rows=%d start=%.3fs filter=%.4fs page=%.4fs search=%.3fs",
                sourceCount * (1 + documentsPerSource), startTime, filterTime, pageTime, searchTime))
        XCTAssertLessThan(startTime, 5, "initial load and join")
        XCTAssertLessThan(filterTime, 0.5, "one filter change over 8,000 rows")
        XCTAssertLessThan(pageTime, 0.25, "one more page")
        XCTAssertLessThan(searchTime, 5, "a search over 8,000 rows, off the main actor")
    }
}

extension Duration {
    fileprivate var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
