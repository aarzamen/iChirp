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
///
/// The owner runs several builds against the same settings, so the blob is read entry by entry and written back
/// without losing what this build cannot read (review R1-7, R4-6). A provider entry it cannot decode (a kind a newer
/// build added) is left out of `loadProviders()` but kept, in its place, by every save; keys a newer build added to
/// an entry or to the blob survive; and a blob that cannot be read at all is copied to `unreadableKey` (a later,
/// different one to `unreadableKey.2`, and so on) before the first save replaces it.
public final class UserDefaultsLanguageModelProviderStore: LanguageModelProviderStoring, @unchecked Sendable {
    /// The `UserDefaults` key holding the encoded providers (never a key).
    public static let key = "ichirp.languageModelProviders"
    /// Where a blob this build cannot read at all is copied before a save replaces it.
    public static let unreadableKey = "ichirp.languageModelProviders.unreadable"

    /// The blob as read: the providers this build can decode, and everything else, kept for the next save.
    struct Stored {
        static let providersKey = "providers"
        static let defaultProviderIDKey = "defaultProviderID"
        /// M7; absent in older saves (reads as nil).
        static let defaultLocalModelIDKey = "defaultLocalModelID"

        /// One stored provider entry: decoded (with its JSON object, which may hold keys of a newer build), or one
        /// this build cannot decode, kept exactly as stored.
        enum Entry {
            case provider(LanguageModelProviderConfiguration, object: [String: Any])
            case unreadable(Any)
        }

        /// Every entry, in stored order.
        var entries: [Entry] = []
        /// The blob's top-level object. A save rewrites its known keys and keeps every other one.
        var object: [String: Any] = [:]
        /// The stored bytes when the blob could not be read at all; a save copies them aside first.
        var unreadableData: Data?

        var providers: [LanguageModelProviderConfiguration] {
            entries.compactMap { entry in
                if case .provider(let provider, _) = entry { provider } else { nil }
            }
        }

        /// Nil when absent or not a UUID; a value this build cannot read stays stored until the person sets another.
        var defaultProviderID: UUID? {
            get { (object[Self.defaultProviderIDKey] as? String).flatMap(UUID.init(uuidString:)) }
            set { set(newValue?.uuidString, for: Self.defaultProviderIDKey) }
        }

        var defaultLocalModelID: String? {
            get { object[Self.defaultLocalModelIDKey] as? String }
            set { set(newValue, for: Self.defaultLocalModelIDKey) }
        }

        /// Replaces the provider with `provider.id` (keeping the keys of its entry this build does not write), or
        /// appends it.
        mutating func upsert(_ provider: LanguageModelProviderConfiguration) throws {
            let encoded = try Self.object(encoding: provider)
            let index = entries.firstIndex { entry in
                if case .provider(let stored, _) = entry { stored.id == provider.id } else { false }
            }
            guard let index, case .provider(_, let previous) = entries[index] else {
                entries.append(.provider(provider, object: encoded))
                return
            }
            let written = Set(LanguageModelProviderConfiguration.CodingKeys.allCases.map(\.stringValue))
            let kept = previous.filter { !written.contains($0.key) }
            entries[index] = .provider(provider, object: kept.merging(encoded) { _, new in new })
        }

        /// Removes the provider with `id`; an entry this build cannot read is never removed.
        mutating func remove(id: UUID) {
            entries.removeAll { entry in
                if case .provider(let provider, _) = entry { provider.id == id } else { false }
            }
        }

        /// The blob to store: the kept object with its providers and default ids as they are now.
        func encoded() throws -> Data {
            var blob = object
            blob[Self.providersKey] = entries.map { entry -> Any in
                switch entry {
                case .provider(_, let object): object
                case .unreadable(let raw): raw
                }
            }
            guard JSONSerialization.isValidJSONObject(blob) else {
                throw EncodingError.invalidValue(
                    blob, .init(codingPath: [], debugDescription: "The provider settings are not valid JSON."))
            }
            return try JSONSerialization.data(withJSONObject: blob)
        }

        private mutating func set(_ value: String?, for key: String) {
            if let value {
                object[key] = value
            } else {
                object.removeValue(forKey: key)
            }
        }

        private static func object(encoding provider: LanguageModelProviderConfiguration) throws -> [String: Any] {
            let data = try JSONEncoder().encode(provider)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw EncodingError.invalidValue(
                    provider, .init(codingPath: [], debugDescription: "A provider did not encode as an object."))
            }
            return object
        }
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
            try stored.upsert(provider)
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
            stored.remove(id: id)
            if stored.defaultProviderID == id { stored.defaultProviderID = nil }
            try save(stored)
        }
        logger.info("provider_deleted id=\(id, privacy: .public)")
    }

    public func apiKey(for provider: LanguageModelProviderConfiguration) throws -> SecretValue? {
        try secrets.secret(forAccount: provider.secretAccount)
    }

    // MARK: - Private (call with the lock held)

    /// Reads the blob entry by entry. Logs carry an entry's index and an error type only, never a field.
    private func load() -> Stored {
        guard let data = defaults.data(forKey: Self.key) else { return Stored() }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            logger.error("providers_unreadable reason=not_an_object")
            return Stored(unreadableData: data)
        }
        let rawEntries: [Any]
        switch object[Stored.providersKey] {
        case nil: rawEntries = []
        case let list as [Any]: rawEntries = list
        default:
            logger.error("providers_unreadable reason=providers_not_a_list")
            return Stored(unreadableData: data)
        }
        var stored = Stored(object: object)
        for (index, raw) in rawEntries.enumerated() {
            do {
                guard let entry = raw as? [String: Any], JSONSerialization.isValidJSONObject(entry) else {
                    throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Not an object."))
                }
                let provider = try JSONDecoder().decode(
                    LanguageModelProviderConfiguration.self, from: JSONSerialization.data(withJSONObject: entry))
                stored.entries.append(.provider(provider, object: entry))
            } catch {
                logger.error(
                    "provider_entry_unreadable index=\(index, privacy: .public) error_type=\(error.logTypeName, privacy: .public)"
                )
                stored.entries.append(.unreadable(raw))
            }
        }
        return stored
    }

    private func save(_ stored: Stored) throws {
        let data = try stored.encoded()
        if let unreadable = stored.unreadableData { keepUnreadableCopy(unreadable) }
        defaults.set(data, forKey: Self.key)
    }

    /// Copies an unreadable blob aside: to `unreadableKey`, or the first free `unreadableKey.<n>` when an earlier,
    /// different copy is there. A copy is never replaced.
    private func keepUnreadableCopy(_ data: Data) {
        var key = Self.unreadableKey
        var number = 1
        while let kept = defaults.data(forKey: key) {
            if kept == data { return }
            number += 1
            key = "\(Self.unreadableKey).\(number)"
        }
        defaults.set(data, forKey: key)
        logger.notice("providers_unreadable_copied key=\(key, privacy: .public)")
    }
}
