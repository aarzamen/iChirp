// Semantics from MacParakeet (GPL-3.0): Sources/MacParakeetCore/Services/LLM/LLMConfigStore.swift @ bbae9e0e —
// provider metadata in UserDefaults, one Keychain item per provider, the Keychain write completing before the
// metadata changes. Fresh implementation: several providers instead of one, and a trusted-LAN-host flag.

import ChirpCore
import Foundation

/// What happens to a provider's API key when the provider is saved.
public enum APIKeyChange: Sendable, Equatable {
    /// Leave the stored key as it is.
    case keep
    case set(SecretValue)
    case remove
}

/// The user's language-model providers (Settings → Models) and their API keys.
///
/// Provider metadata may live anywhere; **keys only in the injected `SecretStoring`** (the Keychain), never in
/// `UserDefaults`, files, the database or logs (spec/12-privacy.md).
public protocol LanguageModelProviderStoring: Sendable {
    /// Providers in the order the user added them.
    func loadProviders() -> [LanguageModelProviderConfiguration]
    /// The provider Transform and Ask use when none is picked, if it still exists.
    func defaultProviderID() -> UUID?
    func setDefaultProviderID(_ id: UUID?) throws
    /// M7: the small on-device model (`LocalModelOption.id`) Transform and Ask use when no provider is the default.
    func defaultLocalModelID() -> String?
    func setDefaultLocalModelID(_ id: String?) throws
    /// Validates, then creates or replaces the provider (by `id`) and applies `apiKey`.
    func saveProvider(_ provider: LanguageModelProviderConfiguration, apiKey: APIKeyChange) throws
    /// Removes the provider and its key.
    func deleteProvider(id: UUID) throws
    /// The provider's key from the secret store, for building its engine right before a run or a connection test.
    func apiKey(for provider: LanguageModelProviderConfiguration) throws -> SecretValue?
}

extension LanguageModelProviderStoring {
    /// The routing policy for the current providers: trusts exactly the LAN hosts the user marked trusted.
    public func routingPolicy() -> PrivacyRoutingPolicy {
        PrivacyRoutingPolicy(trustingLocalNetworkHostsOf: loadProviders())
    }
}

/// `LanguageModelProviderStoring` with metadata as one JSON blob in `UserDefaults` and keys in a `SecretStoring`.
/// `UserDefaults` and the Keychain are documented thread-safe, hence `@unchecked Sendable`.
public final class UserDefaultsLanguageModelProviderStore: LanguageModelProviderStoring, @unchecked Sendable {
    /// The `UserDefaults` key holding the encoded providers (never a key).
    public static let key = "ichirp.languageModelProviders"

    struct Stored: Codable, Equatable {
        var providers: [LanguageModelProviderConfiguration] = []
        var defaultProviderID: UUID?
        /// M7; absent in older saves (decodes as nil).
        var defaultLocalModelID: String?
    }

    private let defaults: UserDefaults
    private let secrets: any SecretStoring
    private let lock = NSLock()
    private let logger = Log.logger("providers")

    public init(defaults: UserDefaults = .standard, secrets: any SecretStoring) {
        self.defaults = defaults
        self.secrets = secrets
    }

    public func loadProviders() -> [LanguageModelProviderConfiguration] {
        lock.withLock { load().providers }
    }

    public func defaultProviderID() -> UUID? {
        lock.withLock {
            let stored = load()
            guard let id = stored.defaultProviderID, stored.providers.contains(where: { $0.id == id }) else {
                return nil
            }
            return id
        }
    }

    public func setDefaultProviderID(_ id: UUID?) throws {
        try lock.withLock {
            var stored = load()
            stored.defaultProviderID = id
            try save(stored)
        }
    }

    public func defaultLocalModelID() -> String? {
        lock.withLock { load().defaultLocalModelID }
    }

    public func setDefaultLocalModelID(_ id: String?) throws {
        try lock.withLock {
            var stored = load()
            stored.defaultLocalModelID = id
            try save(stored)
        }
    }

    public func saveProvider(_ provider: LanguageModelProviderConfiguration, apiKey: APIKeyChange) throws {
        try provider.validate()
        try lock.withLock {
            // The Keychain write completes before the metadata changes (upstream order), so a failed key save never
            // leaves a provider that claims a key it does not have.
            switch apiKey {
            case .keep:
                break
            case .set(let secret):
                if secret.isEmpty {
                    try secrets.deleteSecret(forAccount: provider.secretAccount)
                } else {
                    try secrets.setSecret(secret, forAccount: provider.secretAccount)
                }
            case .remove:
                try secrets.deleteSecret(forAccount: provider.secretAccount)
            }
            var stored = load()
            if let index = stored.providers.firstIndex(where: { $0.id == provider.id }) {
                stored.providers[index] = provider
            } else {
                stored.providers.append(provider)
            }
            try save(stored)
        }
        logger.info(
            "provider_saved id=\(provider.id, privacy: .public) kind=\(provider.kind.rawValue, privacy: .public) locality=\(provider.locality.rawValue, privacy: .public) trusted=\(provider.isTrustedLocalNetworkHost, privacy: .public)"
        )
    }

    public func deleteProvider(id: UUID) throws {
        try lock.withLock {
            var stored = load()
            guard let provider = stored.providers.first(where: { $0.id == id }) else { return }
            try secrets.deleteSecret(forAccount: provider.secretAccount)
            stored.providers.removeAll { $0.id == id }
            if stored.defaultProviderID == id { stored.defaultProviderID = nil }
            try save(stored)
        }
        logger.info("provider_deleted id=\(id, privacy: .public)")
    }

    public func apiKey(for provider: LanguageModelProviderConfiguration) throws -> SecretValue? {
        try secrets.secret(forAccount: provider.secretAccount)
    }

    // MARK: - Private (call with the lock held)

    private func load() -> Stored {
        guard let data = defaults.data(forKey: Self.key) else { return Stored() }
        do {
            return try JSONDecoder().decode(Stored.self, from: data)
        } catch {
            logger.error("providers_decode_failed error_type=\(error.logTypeName, privacy: .public)")
            return Stored()
        }
    }

    private func save(_ stored: Stored) throws {
        defaults.set(try JSONEncoder().encode(stored), forKey: Self.key)
    }
}
