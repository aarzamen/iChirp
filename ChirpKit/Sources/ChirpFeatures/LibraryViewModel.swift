import ChirpCore
import ChirpExport
import Foundation
import Observation

/// A generated document as the Library shows it (plan 023, UX audit F43): its stored summary, the item it was made from
/// and the class the privacy rules use for it.
public struct LibraryDocument: Sendable, Equatable, Identifiable {
    public let summary: DeliverableSummary
    /// The source item's title; nil when that item is not in the Library (a row this build cannot read).
    public let sourceTitle: String?
    public let sourceType: Transcription.SourceType?
    /// The stricter of the document's own class, its source's class and every other document made from that source
    /// (`EffectivePrivacyClass`: the class Listen, Share and Transform use). Clinical when the source is unknown.
    public let effectivePrivacyClass: PrivacyClass

    public init(
        summary: DeliverableSummary,
        sourceTitle: String?,
        sourceType: Transcription.SourceType?,
        effectivePrivacyClass: PrivacyClass
    ) {
        self.summary = summary
        self.sourceTitle = sourceTitle
        self.sourceType = sourceType
        self.effectivePrivacyClass = effectivePrivacyClass
    }

    public var id: UUID { summary.id }
    public var createdAt: Date { summary.createdAt }
    /// The template name ("SOAP note"): the row's type badge.
    public var typeTitle: String { summary.title }
}

/// One Library row: a recording, typed text or imported document (`Transcription`), or a generated document.
public enum LibraryEntry: Sendable, Equatable, Identifiable {
    case item(Transcription)
    case document(LibraryDocument)

    /// Transcriptions and documents have separate id spaces.
    public enum ID: Hashable, Sendable {
        case item(UUID)
        case document(UUID)
    }

    public var id: ID {
        switch self {
        case .item(let item): .item(item.id)
        case .document(let document): .document(document.id)
        }
    }

    public var createdAt: Date {
        switch self {
        case .item(let item): item.createdAt
        case .document(let document): document.createdAt
        }
    }
}

/// The rows of one day: "Today", "Yesterday", "Sep 19" (and the year for another year's days).
public struct LibrarySection: Sendable, Equatable, Identifiable {
    public let day: Date
    public let title: String
    public let entries: [LibraryEntry]

    public var id: Date { day }
}

/// The Library screen: every transcription and (plan 023, UX audit F43) every generated document, newest first, with
/// filter chips, search and day sections, shown a page at a time so thousands of rows stay smooth.
///
/// Nothing is capped: `showMore()` adds pages until `hasMore` is false, and the Documents filter and search reach every
/// document. Filtering and paging run on the main actor over values already in memory (linear, a few milliseconds for
/// thousands of rows); search reads transcript text off the main actor and document text in the store.
@MainActor @Observable public final class LibraryViewModel {
    /// The Library's filter chips. F63 (renaming "Video" and "Local") is still the owner's decision.
    public enum Filter: String, CaseIterable, Sendable {
        case all, meetings, dictations, video, local, documents

        /// Chip label.
        public var title: String {
            switch self {
            case .all: "All"
            case .meetings: "Meetings"
            case .dictations: "Dictations"
            case .video: "Video"
            case .local: "Local"
            case .documents: "Documents"
            }
        }

        /// `.video` means link sources (URL, podcast); `.local` means files, documents and typed text from the device;
        /// `.documents` holds only generated documents, so it includes no source type.
        public func includes(_ sourceType: Transcription.SourceType) -> Bool {
            switch self {
            case .all: true
            case .meetings: sourceType == .meeting
            case .dictations: sourceType == .dictation
            case .video: sourceType == .url || sourceType == .podcast
            case .local: sourceType == .file || sourceType == .document || sourceType == .text
            case .documents: false
            }
        }

        /// Generated documents (SOAP notes, summaries, any template's output) show under All and Documents.
        public var includesGeneratedDocuments: Bool {
            self == .all || self == .documents
        }
    }

    /// Every transcription in the store, newest first, kept current while `start()`'s observation runs.
    public private(set) var items: [Transcription] = [] {
        didSet { dataChanged() }
    }
    /// Every generated document, newest first (empty when the Library has no `DeliverableListing`).
    public private(set) var documents: [LibraryDocument] = []
    public var filter: Filter = .all {
        didSet {
            guard filter != oldValue else { return }
            displayLimit = pageSize
            rebuildEntries()
        }
    }
    public var searchText: String = "" {
        didSet {
            guard searchText != oldValue else { return }
            displayLimit = pageSize
            scheduleSearch(debounced: true)
        }
    }
    /// Everything `filter` and the settled search let through, newest first: every page, not only the shown ones.
    public private(set) var visibleEntries: [LibraryEntry] = []
    /// The shown pages of `visibleEntries`, grouped by day.
    public private(set) var sections: [LibrarySection] = []
    /// `visibleEntries` holds more rows than `sections` shows; `showMore()` adds the next page.
    public private(set) var hasMore = false
    /// A search for the current text is still running; the list shows the previous result meanwhile.
    public private(set) var isSearching = false
    /// Set when the text of the documents could not be searched (titles still were).
    public private(set) var searchError: String?
    /// Set when the initial load failed; the observation may still fill `items` later.
    public private(set) var loadError: String?
    /// How many rows a page adds.
    public let pageSize: Int
    /// Each source item's documents, newest first (`documents(madeFrom:)`).
    private var documentsBySource: [UUID: [LibraryDocument]] = [:]

    @ObservationIgnored private let store: any TranscriptionStoring
    @ObservationIgnored private let listing: (any DeliverableListing)?
    @ObservationIgnored private let paths: AppPaths
    @ObservationIgnored private let calendar: Calendar
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let searchDebounce: Duration
    @ObservationIgnored private var summaries: [DeliverableSummary] = [] {
        didSet { dataChanged() }
    }
    /// How many rows of `visibleEntries` `sections` shows.
    @ObservationIgnored private var displayLimit: Int
    @ObservationIgnored private var matches: SearchMatches?
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var observation: Task<Void, Never>?
    @ObservationIgnored private var documentObservation: Task<Void, Never>?
    @ObservationIgnored private let logger = Log.logger("library")

    /// The rows that matched a settled search.
    private struct SearchMatches {
        let items: Set<UUID>
        let documents: Set<UUID>
    }

    /// - Parameters:
    ///   - paths: used by `delete` to remove the item's `media/<id>/` folder along with its row.
    ///   - documents: the generated documents' lists (`GRDBDeliverableStore` in the app); nil shows transcriptions only.
    ///   - pageSize: rows per page (the first page, and each `showMore()`).
    ///   - searchDebounce: how long typing must pause before a search runs.
    ///   - calendar, now: the device calendar and clock; injectable for tests.
    public init(
        store: any TranscriptionStoring,
        paths: AppPaths,
        documents: (any DeliverableListing)? = nil,
        pageSize: Int = 100,
        searchDebounce: Duration = .milliseconds(150),
        calendar: Calendar = .current,
        now: @escaping () -> Date = { Date() }
    ) {
        self.store = store
        self.listing = documents
        self.paths = paths
        self.pageSize = max(1, pageSize)
        self.displayLimit = max(1, pageSize)
        self.searchDebounce = searchDebounce
        self.calendar = calendar
        self.now = now
    }

    isolated deinit {
        observation?.cancel()
        documentObservation?.cancel()
        searchTask?.cancel()
    }

    // MARK: - Derived lists

    /// The transcriptions among `visibleEntries`.
    public var visibleItems: [Transcription] {
        visibleEntries.compactMap { entry in
            if case .item(let item) = entry { item } else { nil }
        }
    }

    /// The generated documents among `visibleEntries`.
    public var visibleDocuments: [LibraryDocument] {
        visibleEntries.compactMap { entry in
            if case .document(let document) = entry { document } else { nil }
        }
    }

    /// The documents made from one item, newest first (the order of `DeliverableStoring.fetchDeliverables`).
    public func documents(madeFrom sourceID: UUID) -> [LibraryDocument] {
        documentsBySource[sourceID] ?? []
    }

    // MARK: - Lifecycle

    /// Loads the rows and the documents, then keeps both current from the store observations until `stop()` or
    /// deinit.
    public func start() async {
        let stream = store.observeAll()
        let documentStream = listing?.observeDeliverableSummaries()
        do {
            items = try await store.fetchAll()
            loadError = nil
        } catch {
            loadError = error.localizedDescription
            logger.error(
                "library_load_failed error_type=\(error.logTypeName, privacy: .public) error=\(error.localizedDescription, privacy: .private)"
            )
        }
        if let listing {
            do {
                summaries = try await listing.fetchDeliverableSummaries()
            } catch {
                loadError = error.localizedDescription
                logger.error(
                    "library_documents_load_failed error_type=\(error.logTypeName, privacy: .public) error=\(error.localizedDescription, privacy: .private)"
                )
            }
        }
        observation?.cancel()
        observation = Task { @MainActor [weak self] in
            for await rows in stream {
                guard let self else { return }
                self.items = rows
            }
        }
        documentObservation?.cancel()
        documentObservation = nil
        if let documentStream {
            documentObservation = Task { @MainActor [weak self] in
                for await summaries in documentStream {
                    guard let self else { return }
                    self.summaries = summaries
                }
            }
        }
    }

    /// Ends the store observations and any search in flight.
    public func stop() {
        observation?.cancel()
        observation = nil
        documentObservation?.cancel()
        documentObservation = nil
        searchTask?.cancel()
        searchTask = nil
    }

    /// Clears `loadError` (the alert's dismiss action).
    public func dismissLoadError() {
        loadError = nil
    }

    /// Adds the next page of `visibleEntries` to `sections` (the screen calls it as the last shown row appears).
    public func showMore() {
        guard hasMore else { return }
        displayLimit += pageSize
        rebuildSections()
    }

    /// Returns once the search for the current text has settled (tests, and anything that must read its result).
    public func searchSettled() async {
        var awaited: Task<Void, Never>?
        while let task = searchTask, task != awaited {
            awaited = task
            await task.value
        }
    }

    // MARK: - Mutations

    /// Deletes the row, then its `media/<id>/` folder (source audio included). Call only after the user confirmed.
    /// Cancel a running job for `id` first (`TranscriptionJobCenter.cancel`); the pipeline never recreates a row
    /// deleted under it. The store deletes the documents made from it with it (a cascade); they leave the list now.
    public func delete(_ id: UUID) async throws {
        try await store.delete(id: id)
        items.removeAll { $0.id == id }
        summaries.removeAll { $0.transcriptionID == id }
        ExportTempFiles.remove(for: id)
        let folder = paths.mediaDirectory(for: id)
        guard FileManager.default.fileExists(atPath: folder.path) else { return }
        do {
            try FileManager.default.removeItem(at: folder)
        } catch {
            // The row is gone either way; a leftover folder is only disk space.
            let reason = error.localizedDescription
            logger.error(
                "media_delete_failed id=\(id, privacy: .public) error_type=\(error.logTypeName, privacy: .public) error=\(reason, privacy: .private)"
            )
        }
    }

    /// Flips the star with a field-level store write, so it can never overwrite a job's output that lands meanwhile.
    public func toggleFavorite(_ id: UUID) async throws {
        guard let current = try await store.fetch(id: id),
            let updated = try await store.updateFavorite(id: id, isFavorite: !current.isFavorite)
        else { return }
        if let index = items.firstIndex(where: { $0.id == id }) {
            items[index] = updated
        }
    }

    // MARK: - Rebuilding the lists

    /// Rows or documents changed: rebuild everything derived from them, and search the new rows again.
    private func dataChanged() {
        rebuildDocuments()
        rebuildEntries()
        if !normalizedQuery.isEmpty {
            scheduleSearch(debounced: true)
        }
    }

    /// Joins each summary with its source item (title, kind) and works out its effective class.
    private func rebuildDocuments() {
        guard !summaries.isEmpty else {
            if !documents.isEmpty { documents = [] }
            if !documentsBySource.isEmpty { documentsBySource = [:] }
            return
        }
        var sources: [UUID: Transcription] = [:]
        sources.reserveCapacity(items.count)
        for item in items where sources[item.id] == nil {
            sources[item.id] = item
        }
        var strictestDocument: [UUID: PrivacyClass] = [:]
        for summary in summaries {
            strictestDocument[summary.transcriptionID] =
                strictestDocument[summary.transcriptionID]?.stricter(summary.privacyClass) ?? summary.privacyClass
        }
        var bySource: [UUID: [LibraryDocument]] = [:]
        var joined: [LibraryDocument] = []
        joined.reserveCapacity(summaries.count)
        for summary in summaries {
            let source = sources[summary.transcriptionID]
            let siblings = strictestDocument[summary.transcriptionID] ?? summary.privacyClass
            let document = LibraryDocument(
                summary: summary,
                sourceTitle: source?.displayTitle,
                sourceType: source?.sourceType,
                effectivePrivacyClass: (source?.privacyClass ?? .clinical).stricter(siblings))
            joined.append(document)
            bySource[summary.transcriptionID, default: []].append(document)
        }
        documents = joined
        documentsBySource = bySource
    }

    /// `items` and `documents` narrowed by `filter` and the settled search, merged newest first.
    private func rebuildEntries() {
        let matches = self.matches
        let filter = self.filter
        let shownItems = items.filter { item in
            filter.includes(item.sourceType) && (matches?.items.contains(item.id) ?? true)
        }
        let shownDocuments =
            filter.includesGeneratedDocuments
            ? documents.filter { matches?.documents.contains($0.id) ?? true } : []
        visibleEntries = Self.mergedNewestFirst(shownItems, shownDocuments)
        rebuildSections()
    }

    /// Both inputs arrive newest first from their stores; a merge keeps every row of both (an input that is not
    /// perfectly ordered only changes the order, never what is listed). An item wins a tie with a document.
    nonisolated static func mergedNewestFirst(_ items: [Transcription], _ documents: [LibraryDocument])
        -> [LibraryEntry]
    {
        var merged: [LibraryEntry] = []
        merged.reserveCapacity(items.count + documents.count)
        var itemIndex = 0
        var documentIndex = 0
        while itemIndex < items.count || documentIndex < documents.count {
            let takeDocument =
                itemIndex == items.count
                || (documentIndex < documents.count
                    && documents[documentIndex].createdAt > items[itemIndex].createdAt)
            if takeDocument {
                merged.append(.document(documents[documentIndex]))
                documentIndex += 1
            } else {
                merged.append(.item(items[itemIndex]))
                itemIndex += 1
            }
        }
        return merged
    }

    /// The first `displayLimit` visible rows grouped by the day they were created.
    private func rebuildSections() {
        let shown = visibleEntries.prefix(displayLimit)
        hasMore = visibleEntries.count > displayLimit
        var days: [Date] = []
        var entriesByDay: [Date: [LibraryEntry]] = [:]
        for entry in shown {
            let day = calendar.startOfDay(for: entry.createdAt)
            if entriesByDay[day] == nil { days.append(day) }
            entriesByDay[day, default: []].append(entry)
        }
        let today = calendar.startOfDay(for: now())
        sections = days.map { day in
            LibrarySection(day: day, title: sectionTitle(for: day, today: today), entries: entriesByDay[day] ?? [])
        }
    }

    // MARK: - Search

    private var normalizedQuery: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Starts (after `searchDebounce` when typing) a search for the current text; an empty text clears it at once.
    private func scheduleSearch(debounced: Bool) {
        searchTask?.cancel()
        let query = normalizedQuery
        guard !query.isEmpty else {
            searchTask = nil
            isSearching = false
            searchError = nil
            if matches != nil {
                matches = nil
                rebuildEntries()
            }
            return
        }
        isSearching = true
        let delay = debounced ? searchDebounce : .zero
        searchTask = Task { [weak self] in
            if delay > .zero {
                try? await Task.sleep(for: delay)
                if Task.isCancelled { return }
            }
            await self?.runSearch(query)
        }
    }

    /// Transcripts: title, text, file name and speaker labels, compared off the main actor. Documents: template name
    /// and source title here, text in the store. Lands only if the text is still `query`.
    private func runSearch(_ query: String) async {
        let rows = items
        let documentRows = documents
        let itemMatches = await Task.detached(priority: .userInitiated) {
            Self.itemIDs(in: rows, matching: query)
        }.value
        var documentMatches = Set<UUID>()
        var failure: String?
        if let listing, !documentRows.isEmpty {
            do {
                documentMatches = try await listing.searchDeliverables(matching: query)
            } catch {
                failure = error.localizedDescription
                logger.error(
                    "library_document_search_failed error_type=\(error.logTypeName, privacy: .public) error=\(error.localizedDescription, privacy: .private)"
                )
            }
        }
        for document in documentRows where Self.matches(document, query: query) {
            documentMatches.insert(document.id)
        }
        guard !Task.isCancelled, normalizedQuery == query else { return }
        matches = SearchMatches(items: itemMatches, documents: documentMatches)
        searchError = failure
        isSearching = false
        rebuildEntries()
    }

    nonisolated static func itemIDs(in items: [Transcription], matching query: String) -> Set<UUID> {
        Set(items.lazy.filter { matches($0, query: query) }.map(\.id))
    }

    /// Case-insensitive over title, text, file name and speaker labels.
    nonisolated static func matches(_ item: Transcription, query: String) -> Bool {
        item.displayTitle.localizedCaseInsensitiveContains(query)
            || item.displayText.localizedCaseInsensitiveContains(query)
            || item.fileName.localizedCaseInsensitiveContains(query)
            || (item.speakers ?? []).contains { $0.label.localizedCaseInsensitiveContains(query) }
    }

    /// A document's template name or its source's title (its text is searched in the store).
    nonisolated static func matches(_ document: LibraryDocument, query: String) -> Bool {
        document.typeTitle.localizedCaseInsensitiveContains(query)
            || (document.sourceTitle?.localizedCaseInsensitiveContains(query) ?? false)
    }

    // MARK: - Helpers

    private func sectionTitle(for day: Date, today: Date) -> String {
        if day == today {
            return "Today"
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: today), day == yesterday {
            return "Yesterday"
        }
        let base = Date.FormatStyle(
            locale: calendar.locale ?? .current,
            calendar: calendar,
            timeZone: calendar.timeZone
        )
        .month(.abbreviated).day()
        // Another year's "Sep 19" names its year, so two years' sections never share a title.
        let sameYear = calendar.component(.year, from: day) == calendar.component(.year, from: today)
        return day.formatted(sameYear ? base : base.year())
    }
}
