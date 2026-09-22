import ChirpCore
import Foundation

/// Where the user's `TranscriptionSettings` live. Reads and writes are synchronous and cheap; the pipeline reads
/// the settings once per job, so a change applies to the next job, never to one already running.
public protocol SettingsStoring: Sendable {
    func load() -> TranscriptionSettings
    func save(_ settings: TranscriptionSettings)
}

/// `SettingsStoring` backed by `UserDefaults`, as one JSON blob under `key`.
///
/// Decoding is forgiving (see `TranscriptionSettings.init(from:)`): a missing or unreadable value yields the
/// defaults instead of failing. `UserDefaults` is documented thread-safe, hence `@unchecked Sendable`.
public final class UserDefaultsSettingsStore: SettingsStoring, @unchecked Sendable {
    /// The `UserDefaults` key holding the encoded settings.
    public static let key = "ichirp.transcriptionSettings"

    private let defaults: UserDefaults
    private let logger = Log.logger("settings")

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> TranscriptionSettings {
        guard let data = defaults.data(forKey: Self.key) else {
            return TranscriptionSettings()
        }
        do {
            return try JSONDecoder().decode(TranscriptionSettings.self, from: data)
        } catch {
            logger.error("settings_decode_failed; using defaults")
            return TranscriptionSettings()
        }
    }

    public func save(_ settings: TranscriptionSettings) {
        do {
            defaults.set(try JSONEncoder().encode(settings), forKey: Self.key)
        } catch {
            logger.error(
                "settings_encode_failed error_type=\(error.logTypeName, privacy: .public) error=\(error.localizedDescription, privacy: .private)"
            )
        }
    }
}
