/// A secret (an API key) held in memory. Its `description`, `debugDescription` and mirror are redacted, so string
/// interpolation, `print`, `dump` and logging never show the value; only `reveal()` does, at the one place that puts
/// it on the wire.
public struct SecretValue: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible,
    CustomReflectable
{
    private let value: String

    public init(_ value: String) {
        self.value = value
    }

    /// The raw secret. Call only where it is written to a request header or to the secret store.
    public func reveal() -> String { value }

    public var isEmpty: Bool { value.isEmpty }

    public var description: String { "<redacted>" }
    public var debugDescription: String { "SecretValue(<redacted>)" }
    public var customMirror: Mirror { Mirror(self, children: [], displayStyle: .struct) }
}

/// Storage for secrets such as API keys. The shipping conformer is `ChirpKeychain.KeychainSecretStore`; tests use a fake.
///
/// Rules (spec/12-privacy.md): secrets live only here, never in `UserDefaults`, files, the database or logs. An
/// `account` names one secret, for example `LanguageModelProviderConfiguration.secretAccount`.
public protocol SecretStoring: Sendable {
    /// The stored secret, or nil when there is none.
    func secret(forAccount account: String) throws -> SecretValue?
    /// Creates or replaces the secret.
    func setSecret(_ secret: SecretValue, forAccount account: String) throws
    /// Removes the secret; removing a missing secret is not an error.
    func deleteSecret(forAccount account: String) throws
}
