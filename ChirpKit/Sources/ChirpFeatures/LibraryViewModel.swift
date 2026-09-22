import ChirpCore
import ChirpExport
import Foundation
import Observation

/// The Library screen: every transcription, newest first, with source filters, search and day sections.
@MainActor @Observable public final class LibraryViewModel {
    /// The Library's filter chips.
    public enum Filter: String, CaseIterable, Sendable {
        case all, meetings, dictations, video, local

        /// Chip label.
        public var title: String {
            switch self {
            case .all: "All"
            case .meetings: "Meetings"
            case .dictations: "Dictations"
            case .video: "Video"
            case .local: "Local"
            }
        }

        /// `.video` means link sources (URL, podcast); `.local` means files and documents from the device.
        public func includes(_ sourceType: Transcription.SourceType) -> Bool {
            switch self {
            case .all: true
            case .meetings: sourceType == .meeting
            case .dictations: sourceType == .dictation
            case .video: sourceType == .url || sourceType == .podcast
            case .local: sourceType == .file || sourceType == .document
            }
        }
    }

    /// Every row in the store, newest first, kept current while `start()`'s observation runs.
    public private(set) var items: [Transcription] = []
    public var filter: Filter = .all
    public var searchText: String = ""
    /// Set when the initial load failed; the observation may still fill `items` later.
    public private(set) var loadError: String?

    @ObservationIgnored private let store: any TranscriptionStoring
    @ObservationIgnored private let paths: AppPaths
    @ObservationIgnored private let calendar: Calendar
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var observation: Task<Void, Never>?
    @ObservationIgnored private let logger = Log.logger("library")

    /// - Parameters:
    ///   - paths: used by `delete` to remove the item's `media/<id>/` folder along with its row.
    ///   - calendar, now: the device calendar and clock; injectable for tests.
    public init(
        store: any TranscriptionStoring,
        paths: AppPaths,
        calendar: Calendar = .current,
        now: @escaping () -> Date = { Date() }
    ) {
        self.store = store
        self.paths = paths
        self.calendar = calendar
        self.now = now
    }

    isolated deinit {
        observation?.cancel()
    }

    // MARK: - Derived lists

    /// `items` narrowed by `filter` and `searchText` (case-insensitive over title, text, file name and speaker labels).
    public var visibleItems: [Transcription] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return items.filter { item in
            filter.includes(item.sourceType) && (query.isEmpty || Self.matches(item, query: query))
        }
    }

    /// `visibleItems` grouped by the day they were created: "Today", "Yesterday", else "MMM d" (e.g. "Sep 19").
    public var sections: [(title: String, items: [Transcription])] {
        var result: [(title: String, items: [Transcription])] = []
        var sectionIndexByDay: [Date: Int] = [:]
        for item in visibleItems {
            let day = calendar.startOfDay(for: item.createdAt)
            if let index = sectionIndexByDay[day] {
                result[index].items.append(item)
            } else {
                sectionIndexByDay[day] = result.count
                result.append((title: sectionTitle(for: day), items: [item]))
            }
        }
        return result
    }

    // MARK: - Lifecycle

    /// Loads the rows, then keeps `items` current from `observeAll()` until `stop()` or deinit.
    public func start() async {
        let stream = store.observeAll()
        do {
            items = try await store.fetchAll()
            loadError = nil
        } catch {
            loadError = error.localizedDescription
            logger.error(
                "library_load_failed error_type=\(error.logTypeName, privacy: .public) error=\(error.localizedDescription, privacy: .private)"
            )
        }
        observation?.cancel()
        observation = Task { @MainActor [weak self] in
            for await rows in stream {
                guard let self else { return }
                self.items = rows
            }
        }
    }

    /// Ends the store observation.
    public func stop() {
        observation?.cancel()
        observation = nil
    }

    /// Clears `loadError` (the alert's dismiss action).
    public func dismissLoadError() {
        loadError = nil
    }

    // MARK: - Mutations

    /// Deletes the row, then its `media/<id>/` folder (source audio included). Call only after the user confirmed.
    /// Cancel a running job for `id` first (`TranscriptionJobCenter.cancel`); the pipeline never recreates a row
    /// deleted under it.
    public func delete(_ id: UUID) async throws {
        try await store.delete(id: id)
        items.removeAll { $0.id == id }
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

    // MARK: - Helpers

    private func sectionTitle(for day: Date) -> String {
        let today = calendar.startOfDay(for: now())
        if day == today {
            return "Today"
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: today), day == yesterday {
            return "Yesterday"
        }
        let style = Date.FormatStyle(
            locale: calendar.locale ?? .current,
            calendar: calendar,
            timeZone: calendar.timeZone
        )
        .month(.abbreviated).day()
        return day.formatted(style)
    }

    private static func matches(_ item: Transcription, query: String) -> Bool {
        item.displayTitle.localizedCaseInsensitiveContains(query)
            || item.displayText.localizedCaseInsensitiveContains(query)
            || item.fileName.localizedCaseInsensitiveContains(query)
            || (item.speakers ?? []).contains { $0.label.localizedCaseInsensitiveContains(query) }
    }
}
