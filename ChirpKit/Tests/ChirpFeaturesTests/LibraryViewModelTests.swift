import ChirpCore
import ChirpExport
import Foundation
import Synchronization
import XCTest

@testable import ChirpFeatures

@MainActor
final class LibraryViewModelTests: XCTestCase {
    /// 2026-09-22 15:00 UTC.
    private let now = Date(timeIntervalSince1970: 1_790_089_200)

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = Locale(identifier: "en_US")
        return calendar
    }

    private func row(
        _ title: String,
        _ sourceType: Transcription.SourceType,
        daysAgo: Int = 0,
        hoursAgo: Int = 0,
        text: String = ""
    ) -> Transcription {
        let created = now.addingTimeInterval(-Double(daysAgo * 86_400 + hoursAgo * 3_600))
        var transcription = Transcription(
            createdAt: created,
            sourceType: sourceType,
            fileName: "\(title).m4a",
            status: .completed
        )
        transcription.rawTranscript = text
        return transcription
    }

    private func makeViewModel(
        rows: [Transcription],
        paths: AppPaths = AppPaths(root: FileManager.default.temporaryDirectory)
    ) async -> (LibraryViewModel, FakeStore) {
        let store = FakeStore(rows: rows)
        let fixedNow = now
        let viewModel = LibraryViewModel(
            store: store, paths: paths, searchDebounce: .zero, calendar: calendar, now: { fixedNow })
        await viewModel.start()
        addTeardownBlock { @MainActor in viewModel.stop() }
        return (viewModel, store)
    }

    // MARK: - Filters

    func testFilterMeetingsShowsOnlyMeetingRow() async {
        let meeting = row("Standup", .meeting)
        let (viewModel, _) = await makeViewModel(rows: [
            meeting, row("Memo", .dictation), row("Lecture", .file), row("Podcast", .podcast),
        ])

        viewModel.filter = .meetings

        XCTAssertEqual(viewModel.visibleItems.map(\.id), [meeting.id])
        XCTAssertEqual(viewModel.sections.flatMap(\.entries).map(\.id), [.item(meeting.id)])
    }

    func testEveryFilterMapsToItsSourceTypes() async {
        let meeting = row("Standup", .meeting, hoursAgo: 1)
        let dictation = row("Memo", .dictation, hoursAgo: 2)
        let file = row("Lecture", .file, hoursAgo: 3)
        let document = row("Paper", .document, hoursAgo: 4)
        let link = row("Talk", .url, hoursAgo: 5)
        let podcast = row("Show", .podcast, hoursAgo: 6)
        let (viewModel, _) = await makeViewModel(rows: [meeting, dictation, file, document, link, podcast])

        func ids(_ filter: LibraryViewModel.Filter) -> [UUID] {
            viewModel.filter = filter
            return viewModel.visibleItems.map(\.id)
        }

        XCTAssertEqual(ids(.all), [meeting, dictation, file, document, link, podcast].map(\.id))
        XCTAssertEqual(ids(.meetings), [meeting.id])
        XCTAssertEqual(ids(.dictations), [dictation.id])
        XCTAssertEqual(ids(.video), [link.id, podcast.id])
        XCTAssertEqual(ids(.local), [file.id, document.id])
    }

    // MARK: - Search

    func testSearchMatchesTitleAndTextCaseInsensitively() async {
        var titled = row("Quarterly Budget", .file, hoursAgo: 1, text: "numbers and more numbers")
        titled.titleOverride = "Quarterly BUDGET review"
        let spoken = row("Voice note", .dictation, hoursAgo: 2, text: "remember the budget spreadsheet")
        let other = row("Groceries", .dictation, hoursAgo: 3, text: "eggs and milk")
        let (viewModel, _) = await makeViewModel(rows: [titled, spoken, other])

        viewModel.searchText = "  bUdGeT "
        await viewModel.searchSettled()
        XCTAssertEqual(viewModel.visibleItems.map(\.id), [titled.id, spoken.id])

        viewModel.searchText = "MILK"
        await viewModel.searchSettled()
        XCTAssertEqual(viewModel.visibleItems.map(\.id), [other.id])

        viewModel.searchText = ""
        await viewModel.searchSettled()
        XCTAssertEqual(viewModel.visibleItems.count, 3)
    }

    func testSearchCombinesWithFilter() async {
        let meeting = row("Budget sync", .meeting, hoursAgo: 1)
        let memo = row("Budget memo", .dictation, hoursAgo: 2)
        let (viewModel, _) = await makeViewModel(rows: [meeting, memo])

        viewModel.filter = .dictations
        viewModel.searchText = "budget"
        await viewModel.searchSettled()

        XCTAssertEqual(viewModel.visibleItems.map(\.id), [memo.id])
    }

    // MARK: - Sections

    func testSectionsGroupTodayAndYesterday() async {
        let todayLate = row("Today late", .file, hoursAgo: 1)
        let todayEarly = row("Today early", .file, hoursAgo: 5)
        let yesterday = row("Yesterday", .file, daysAgo: 1)
        let older = row("Older", .file, daysAgo: 3)
        let (viewModel, _) = await makeViewModel(rows: [older, yesterday, todayEarly, todayLate])

        let sections = viewModel.sections

        XCTAssertEqual(sections.map(\.title), ["Today", "Yesterday", "Sep 19"])
        XCTAssertEqual(sections[0].entries.map(\.id), [.item(todayLate.id), .item(todayEarly.id)])
        XCTAssertEqual(sections[1].entries.map(\.id), [.item(yesterday.id)])
        XCTAssertEqual(sections[2].entries.map(\.id), [.item(older.id)])
    }

    /// Plan 024 Task 9 (R6a-17): the app re-reads the day titles when it comes back to the foreground, so yesterday's rows
    /// do not stay under "Today" after midnight when nothing was written.
    func testRefreshDayTitlesFollowsTheClockPastMidnight() async {
        final class Clock {
            var date: Date
            init(_ date: Date) { self.date = date }
        }
        let clock = Clock(now)
        let today = row("Morning note", .dictation, hoursAgo: 2)
        let library = LibraryViewModel(
            store: FakeStore(rows: [today]), paths: AppPaths(root: FileManager.default.temporaryDirectory),
            searchDebounce: .zero, calendar: calendar, now: { clock.date })
        await library.start()
        addTeardownBlock { @MainActor in library.stop() }
        XCTAssertEqual(library.sections.map(\.title), ["Today"])

        clock.date = now.addingTimeInterval(12 * 3_600)  // 03:00 the next day; nothing was written
        XCTAssertEqual(library.sections.map(\.title), ["Today"], "titles change only when asked")
        library.refreshDayTitles()
        XCTAssertEqual(library.sections.map(\.title), ["Yesterday"])
    }

    // MARK: - Mutations

    func testDeleteRemovesRowAndItsMediaFolder() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibraryDelete-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: base) }
        let paths = AppPaths(root: base)
        let doomed = row("Doomed", .file, hoursAgo: 1)
        let kept = row("Kept", .file, hoursAgo: 2)
        for id in [doomed.id, kept.id] {
            let folder = paths.mediaDirectory(for: id)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data([1, 2, 3]).write(to: folder.appendingPathComponent("source.m4a"))
        }
        let (viewModel, store) = await makeViewModel(rows: [doomed, kept], paths: paths)

        try await viewModel.delete(doomed.id)

        let stored = try await store.fetchAll()
        XCTAssertEqual(stored.map(\.id), [kept.id])
        // `items` converges through the observation (a snapshot queued before the delete may land first).
        await waitUntil { viewModel.items.map(\.id) == [kept.id] }
        XCTAssertFalse(fileExists(paths.mediaDirectory(for: doomed.id)))
        XCTAssertTrue(fileExists(paths.mediaDirectory(for: kept.id)), "only the deleted item's folder goes")
    }

    func testDeleteRemovesExportTempFolder() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibraryDeleteExport-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: base) }
        let paths = AppPaths(root: base)
        let doomed = row("Doomed", .file, hoursAgo: 1)
        let kept = row("Kept", .file, hoursAgo: 2)
        let doomedExport = ExportTempFiles.directory(for: doomed.id)
        let keptExport = ExportTempFiles.directory(for: kept.id)
        addTeardownBlock { try? FileManager.default.removeItem(at: doomedExport) }
        addTeardownBlock { try? FileManager.default.removeItem(at: keptExport) }
        for export in [doomedExport, keptExport] {
            try FileManager.default.createDirectory(at: export, withIntermediateDirectories: true)
            try Data("transcript".utf8).write(to: export.appendingPathComponent("transcript.txt"))
        }
        let (viewModel, _) = await makeViewModel(rows: [doomed, kept], paths: paths)

        try await viewModel.delete(doomed.id)

        XCTAssertFalse(fileExists(doomedExport), "the deleted row's export temp folder must go with it")
        XCTAssertTrue(fileExists(keptExport), "only the deleted item's export folder goes")
    }

    func testToggleFavoriteFlipsAndPersists() async throws {
        let item = row("Star me", .file)
        let (viewModel, store) = await makeViewModel(rows: [item])

        try await viewModel.toggleFavorite(item.id)
        let starred = await store.row(item.id)
        XCTAssertEqual(starred?.isFavorite, true)
        await waitUntil { viewModel.items.first?.isFavorite == true }

        try await viewModel.toggleFavorite(item.id)
        let unstarred = await store.row(item.id)
        XCTAssertEqual(unstarred?.isFavorite, false)
    }

    func testObservationPicksUpStoreChanges() async throws {
        let first = row("First", .file, hoursAgo: 2)
        let (viewModel, store) = await makeViewModel(rows: [first])
        XCTAssertEqual(viewModel.items.map(\.id), [first.id])

        let second = row("Second", .dictation, hoursAgo: 1)
        try await store.insert(second)
        await waitUntil { viewModel.items.count == 2 }

        XCTAssertEqual(viewModel.items.map(\.id), [second.id, first.id])
    }

    func testLoadErrorIsSurfacedAndDismissable() async {
        let store = FakeStore()
        await store.failFetchAll(with: FakeError(message: "database is locked"))
        let viewModel = LibraryViewModel(store: store, paths: AppPaths(root: FileManager.default.temporaryDirectory))
        await viewModel.start()
        addTeardownBlock { @MainActor in viewModel.stop() }

        XCTAssertEqual(viewModel.loadError, "database is locked")
        viewModel.dismissLoadError()
        XCTAssertNil(viewModel.loadError)
    }

    // MARK: - Races with a running job

    func testFavoriteDuringPipelineCompletionKeepsTranscriptAndFavorite() async throws {
        let h = try PipelineHarness(testCase: self)
        let id = try await h.importSample()
        let viewModel = LibraryViewModel(store: h.store, paths: h.paths)
        await viewModel.start()
        addTeardownBlock { @MainActor in viewModel.stop() }
        let save = await h.store.holdNext([.savePreservingUserMetadata])

        let job = Task { await h.pipeline.process(id: id) }
        await save.entered.wait()
        try await viewModel.toggleFavorite(id)
        save.release.fire()
        _ = await job.value

        let fetched = await h.store.row(id)
        let row = try XCTUnwrap(fetched)
        XCTAssertEqual(row.status, .completed)
        XCTAssertTrue(row.isFavorite)
        XCTAssertEqual(row.rawTranscript, FakeSpeech.helloText)
        XCTAssertEqual(row.wordTimestamps?.count, FakeSpeech.helloWords.count)
        let wholeRowUpdates = await h.store.wholeRowUpdates
        XCTAssertEqual(wholeRowUpdates, 0)
    }

    func testFavoriteWriteLandingAfterCompletionKeepsTranscript() async throws {
        // The interleaving a fetch → whole-row update loses: the view model reads the processing row, the job
        // completes, then the view model's write lands.
        let h = try PipelineHarness(testCase: self)
        let id = try await h.importSample()
        let viewModel = LibraryViewModel(store: h.store, paths: h.paths)
        await viewModel.start()
        addTeardownBlock { @MainActor in viewModel.stop() }
        let write = await h.store.holdNext([.updateFavorite, .update])

        let toggle = Task { try await viewModel.toggleFavorite(id) }
        await write.entered.wait()
        let completed = await h.pipeline.process(id: id)
        XCTAssertEqual(completed?.status, .completed)
        write.release.fire()
        try await toggle.value

        let fetched = await h.store.row(id)
        let row = try XCTUnwrap(fetched)
        XCTAssertEqual(row.status, .completed, "the favorite write must not revert the row to processing")
        XCTAssertTrue(row.isFavorite)
        XCTAssertEqual(row.rawTranscript, FakeSpeech.helloText)
        XCTAssertNotNil(row.transcriptSegments)
    }

    // MARK: - What the lists read (review R1-1, R6a-8)

    func testLibraryAndCaptureObserveSummariesNeverWholeRows() async {
        let rows = (0..<5).map { row("Item \($0)", .file, hoursAgo: $0) }
        let store = ListRecordingStore(FakeStore(rows: rows))
        let library = LibraryViewModel(
            store: store, paths: AppPaths(root: FileManager.default.temporaryDirectory), calendar: calendar,
            now: { [now] in now })
        let capture = CaptureViewModel(store: store)
        await library.start()
        await capture.start()
        addTeardownBlock { @MainActor in
            library.stop()
            capture.stop()
        }

        XCTAssertEqual(store.summaryObservations, [nil, CaptureViewModel.recentCount], "Library: all; Capture: three")
        XCTAssertEqual(store.summaryFetches, [nil, CaptureViewModel.recentCount])
        XCTAssertEqual(store.wholeRowReads, 0, "neither list reads word timings, segments or pages")
        XCTAssertEqual(library.items.map(\.id), rows.map(\.id))
        XCTAssertEqual(capture.recent.map(\.id), rows.prefix(3).map(\.id))
    }

    func testAFailedTextSearchSaysSoAndStillMatchesTitlesAndFileNames() async {
        let titled = row("Budget memo", .dictation, hoursAgo: 1)
        let spoken = row("Voice note", .dictation, hoursAgo: 2, text: "remember the budget")
        let (viewModel, store) = await makeViewModel(rows: [titled, spoken])
        await store.failFetchAll(with: FakeError(message: "database is locked"))

        viewModel.searchText = "budget"
        await viewModel.searchSettled()

        XCTAssertEqual(viewModel.visibleItems.map(\.id), [titled.id], "the title still matches")
        XCTAssertEqual(viewModel.searchError, "database is locked", "the text could not be searched, and it says so")

        await store.failFetchAll(with: nil)
        viewModel.searchText = "remember"
        await viewModel.searchSettled()
        XCTAssertEqual(viewModel.visibleItems.map(\.id), [spoken.id])
        XCTAssertNil(viewModel.searchError)
    }

    // MARK: - Capture

    func testCaptureRecentShowsNewestThree() async throws {
        let rows = (0..<5).map { row("Item \($0)", .file, hoursAgo: $0) }
        let store = FakeStore(rows: rows)
        let viewModel = CaptureViewModel(store: store)
        await viewModel.start()
        addTeardownBlock { @MainActor in viewModel.stop() }

        XCTAssertEqual(viewModel.recent.map(\.id), rows.prefix(3).map(\.id))

        let newest = row("Newest", .dictation, hoursAgo: -1)
        try await store.insert(newest)
        await waitUntil { viewModel.recent.first?.id == newest.id }
        XCTAssertEqual(viewModel.recent.map(\.id), [newest.id] + rows.prefix(2).map(\.id))
    }
}

/// Forwards to a `FakeStore` and records which lists a view model reads (review R6a-8): summary observations and
/// fetches with their limits, and every read of whole rows.
final class ListRecordingStore: TranscriptionStoring {
    private let inner: FakeStore
    private let calls = Mutex(Calls())

    private struct Calls {
        var summaryObservations: [Int?] = []
        var summaryFetches: [Int?] = []
        var wholeRowReads = 0
    }

    init(_ inner: FakeStore) {
        self.inner = inner
    }

    var summaryObservations: [Int?] { calls.withLock { $0.summaryObservations } }
    var summaryFetches: [Int?] { calls.withLock { $0.summaryFetches } }
    /// `fetchAll()` and `observeAll()` calls.
    var wholeRowReads: Int { calls.withLock { $0.wholeRowReads } }

    func fetchSummaries(limit: Int?) async throws -> [TranscriptionSummary] {
        calls.withLock { $0.summaryFetches.append(limit) }
        return try await inner.fetchSummaries(limit: limit)
    }

    func observeSummaries(limit: Int?) -> AsyncStream<[TranscriptionSummary]> {
        calls.withLock { $0.summaryObservations.append(limit) }
        return inner.observeSummaries(limit: limit)
    }

    func searchTranscriptions(matching query: String) async throws -> Set<UUID> {
        try await inner.searchTranscriptions(matching: query)
    }

    func fetchAll() async throws -> [Transcription] {
        calls.withLock { $0.wholeRowReads += 1 }
        return try await inner.fetchAll()
    }

    func observeAll() -> AsyncStream<[Transcription]> {
        calls.withLock { $0.wholeRowReads += 1 }
        return inner.observeAll()
    }

    func insert(_ transcription: Transcription) async throws { try await inner.insert(transcription) }
    func savePreservingUserMetadata(_ transcription: Transcription) async throws -> Transcription? {
        try await inner.savePreservingUserMetadata(transcription)
    }
    func updateTitleOverride(id: UUID, titleOverride: String?) async throws -> Transcription? {
        try await inner.updateTitleOverride(id: id, titleOverride: titleOverride)
    }
    func updateFavorite(id: UUID, isFavorite: Bool) async throws -> Transcription? {
        try await inner.updateFavorite(id: id, isFavorite: isFavorite)
    }
    func updatePrivacyClass(id: UUID, privacyClass: PrivacyClass) async throws -> Transcription? {
        try await inner.updatePrivacyClass(id: id, privacyClass: privacyClass)
    }
    func transitionStatus(
        id: UUID, from: Set<Transcription.Status>, to: Transcription.Status, errorMessage: String?
    ) async throws -> Transcription? {
        try await inner.transitionStatus(id: id, from: from, to: to, errorMessage: errorMessage)
    }
    func fetch(id: UUID) async throws -> Transcription? { try await inner.fetch(id: id) }
    func delete(id: UUID) async throws { try await inner.delete(id: id) }
    func markStaleProcessingAsInterrupted() async throws -> Int { try await inner.markStaleProcessingAsInterrupted() }
    func updateUserNotes(id: UUID, userNotes: String?) async throws -> Transcription? {
        try await inner.updateUserNotes(id: id, userNotes: userNotes)
    }
    func renameSpeaker(id: UUID, speakerId: String, to label: String) async throws -> Transcription? {
        try await inner.renameSpeaker(id: id, speakerId: speakerId, to: label)
    }
    func markAudioRemoved(id: UUID, at date: Date) async throws -> Transcription? {
        try await inner.markAudioRemoved(id: id, at: date)
    }
}
