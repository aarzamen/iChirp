import ChirpCore
import Foundation

/// Jev's settings (Settings → Models → Decision models). Holds **no secret** and no address: the key lives in the
/// Keychain under `JevSettingsStore.secretAccount`, and the address is TypeSafe's unless a DEBUG launch argument
/// overrides it, so encoding this value can never leak a key or redirect content.
public struct JevSettings: Sendable, Equatable {
    /// The pinned versioned model id (an alias answers with another id, which the engine rejects).
    public static let defaultModel = "jev-1.13.0"
    public static let defaultBaseURL = URL(string: "https://api.typesafe.ai")!

    /// Off by default. When off, the Transcript's Jev menu is hidden and `DecisionService` refuses to run.
    public var isEnabled: Bool
    public var model: String
    /// TypeSafe's address, or the DEBUG `-ChirpJevBaseURL` stub. Never stored.
    public var baseURL: URL

    public init(isEnabled: Bool = false, model: String = Self.defaultModel, baseURL: URL = Self.defaultBaseURL) {
        self.isEnabled = isEnabled
        self.model = model
        self.baseURL = baseURL
    }

    /// The lowercased host content goes to.
    public var host: String? {
        baseURL.host(percentEncoded: false)?.lowercased()
    }
}

/// Jev's settings and API key. Keys only in the injected `SecretStoring` (the Keychain), never in `UserDefaults`,
/// files, the database or logs (spec/12-privacy.md).
public protocol JevSettingsStoring: Sendable {
    func load() -> JevSettings
    /// Applies `apiKey` first, then saves the toggle and model (upstream order: a failed key write changes nothing).
    func save(_ settings: JevSettings, apiKey: APIKeyChange) throws
    /// The stored key, for building the engine right before a decision or a connection test.
    func apiKey() throws -> SecretValue?
}

extension JevSettingsStoring {
    /// Whether the Keychain holds a key (the key itself is never loaded into the UI).
    public func hasStoredKey() -> Bool {
        ((try? apiKey()) ?? nil) != nil
    }
}

/// `JevSettingsStoring` with the toggle and model as one small JSON blob in `UserDefaults` and the key in a
/// `SecretStoring`. `UserDefaults` and the Keychain are documented thread-safe, hence `@unchecked Sendable`.
public final class JevSettingsStore: JevSettingsStoring, @unchecked Sendable {
    /// The `UserDefaults` key holding the encoded settings (never a key, never an address).
    public static let key = "ichirp.jevSettings"
    /// The Keychain account of Jev's API key, in the same service as the language-model keys.
    public static let secretAccount = "structure.provider.jev.api-key"

    /// What is written to `UserDefaults`.
    struct Stored: Codable, Equatable {
        var isEnabled = false
        var model = JevSettings.defaultModel
    }

    private let defaults: UserDefaults
    private let secrets: any SecretStoring
    private let baseURL: URL
    private let lock = NSLock()
    private let logger = Log.logger("decision-settings")

    /// - Parameter baseURLOverride: the DEBUG `-ChirpJevBaseURL` stub address; nil (always, in Release) means TypeSafe.
    public init(defaults: UserDefaults = .standard, secrets: any SecretStoring, baseURLOverride: URL? = nil) {
        self.defaults = defaults
        self.secrets = secrets
        baseURL = baseURLOverride ?? JevSettings.defaultBaseURL
    }

    public func load() -> JevSettings {
        let stored = lock.withLock { read() }
        let model = stored.model.trimmingCharacters(in: .whitespacesAndNewlines)
        return JevSettings(
            isEnabled: stored.isEnabled, model: model.isEmpty ? JevSettings.defaultModel : model, baseURL: baseURL)
    }

    public func save(_ settings: JevSettings, apiKey: APIKeyChange) throws {
        try lock.withLock {
            switch apiKey {
            case .keep:
                break
            case .set(let secret):
                if secret.isEmpty {
                    try secrets.deleteSecret(forAccount: Self.secretAccount)
                } else {
                    try secrets.setSecret(secret, forAccount: Self.secretAccount)
                }
            case .remove:
                try secrets.deleteSecret(forAccount: Self.secretAccount)
            }
            let stored = Stored(isEnabled: settings.isEnabled, model: settings.model)
            defaults.set(try JSONEncoder().encode(stored), forKey: Self.key)
        }
        logger.info("jev_settings_saved enabled=\(settings.isEnabled, privacy: .public)")
    }

    public func apiKey() throws -> SecretValue? {
        try secrets.secret(forAccount: Self.secretAccount)
    }

    // Call with the lock held.
    private func read() -> Stored {
        guard let data = defaults.data(forKey: Self.key) else { return Stored() }
        do {
            return try JSONDecoder().decode(Stored.self, from: data)
        } catch {
            logger.error("jev_settings_decode_failed error_type=\(error.logTypeName, privacy: .public)")
            return Stored()
        }
    }
}

/// The app's decision-engine registration (ADR-004): its conformer, `AppDecisionModelFactory`, is the only code that
/// imports `ChirpEngineJev`. Screens never call an engine; decisions go through `DecisionService`.
public protocol DecisionModelFactory: Sendable {
    /// The Jev engine for `settings`, with the key loaded from the Keychain just before. Never touches the network.
    func makeJev(settings: JevSettings, apiKey: SecretValue?) -> any DecisionModel
    /// Settings → Models "Test connection": one question over a fixed synthetic sentence, no user content.
    func testJevConnection(settings: JevSettings, apiKey: SecretValue?) async throws
}
