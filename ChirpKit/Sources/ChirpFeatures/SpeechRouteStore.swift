import ChirpCore
import Foundation

/// Where the live and final speech-engine routes are saved (M7). Reads and writes are synchronous and cheap.
public protocol SpeechRouteStoring: Sendable {
    func load() -> SpeechRouteSelection
    func save(_ selection: SpeechRouteSelection)
}

/// `SpeechRouteStoring` in `UserDefaults`, as one JSON value. Forgiving: a missing or unreadable value is Parakeet on
/// both routes. `UserDefaults` is documented thread-safe, hence `@unchecked Sendable`.
public final class UserDefaultsSpeechRouteStore: SpeechRouteStoring, @unchecked Sendable {
    public static let key = "ichirp.speechRoutes"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> SpeechRouteSelection {
        guard let data = defaults.data(forKey: Self.key),
            let selection = try? JSONDecoder().decode(SpeechRouteSelection.self, from: data)
        else { return .default }
        return selection
    }

    public func save(_ selection: SpeechRouteSelection) {
        guard let data = try? JSONEncoder().encode(selection) else { return }
        defaults.set(data, forKey: Self.key)
    }
}
