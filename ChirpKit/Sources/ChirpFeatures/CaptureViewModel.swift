import ChirpCore
import Foundation
import Observation

/// The Capture screen's "Recent" list: the three newest transcriptions, kept current from the store.
@MainActor @Observable public final class CaptureViewModel {
    public static let recentCount = 3

    /// The newest `recentCount` rows (any status, so running and failed jobs show with their progress or error).
    public private(set) var recent: [Transcription] = []

    @ObservationIgnored private let store: any TranscriptionStoring
    @ObservationIgnored private var observation: Task<Void, Never>?
    @ObservationIgnored private let logger = Log.logger("capture")

    public init(store: any TranscriptionStoring) {
        self.store = store
    }

    isolated deinit {
        observation?.cancel()
    }

    /// Loads the newest rows, then follows `observeAll()` until `stop()` or deinit.
    public func start() async {
        let stream = store.observeAll()
        do {
            recent = Array(try await store.fetchAll().prefix(Self.recentCount))
        } catch {
            logger.error(
                "recent_load_failed error_type=\(error.logTypeName, privacy: .public) error=\(error.localizedDescription, privacy: .private)"
            )
        }
        observation?.cancel()
        observation = Task { @MainActor [weak self] in
            for await rows in stream {
                guard let self else { return }
                self.recent = Array(rows.prefix(Self.recentCount))
            }
        }
    }

    /// Ends the store observation.
    public func stop() {
        observation?.cancel()
        observation = nil
    }
}
