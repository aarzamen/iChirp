import ChirpCore
import Foundation
import Observation

/// The Capture screen's "Recent" list: the three newest transcriptions, kept current from the store by a three-row
/// summary query (review R6a-8), never by re-reading the whole Library.
@MainActor @Observable public final class CaptureViewModel {
    public static let recentCount = 3

    /// The newest `recentCount` rows as their rows show them (any status, so running and failed jobs show with their
    /// progress or error).
    public private(set) var recent: [TranscriptionSummary] = []

    @ObservationIgnored private let store: any TranscriptionStoring
    @ObservationIgnored private var observation: Task<Void, Never>?
    @ObservationIgnored private let logger = Log.logger("capture")

    public init(store: any TranscriptionStoring) {
        self.store = store
    }

    isolated deinit {
        observation?.cancel()
    }

    /// Loads the newest rows, then follows `observeSummaries(limit:)` until `stop()` or deinit.
    public func start() async {
        let stream = store.observeSummaries(limit: Self.recentCount)
        do {
            recent = try await store.fetchSummaries(limit: Self.recentCount)
        } catch {
            logger.error(
                "recent_load_failed error_type=\(error.logTypeName, privacy: .public) error=\(error.localizedDescription, privacy: .private)"
            )
        }
        observation?.cancel()
        observation = Task { @MainActor [weak self] in
            for await rows in stream {
                guard let self else { return }
                self.recent = rows
            }
        }
    }

    /// Ends the store observation.
    public func stop() {
        observation?.cancel()
        observation = nil
    }
}
