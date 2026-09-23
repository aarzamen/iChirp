import ChirpCore
import ChirpIngest
import Foundation

/// Settings → Mac companion: the one companion this iPhone uses (host, port, trusted flag in `UserDefaults`; the
/// pairing token **only** in the injected `SecretStoring`, the Keychain).
///
/// This is the real `CompanionConfiguration` (ChirpCore) that plan 020's `CompanionVoice` reads, and the source of the
/// `CompanionClient` that fetches YouTube audio. Every read goes to storage, so a change in Settings applies to the
/// next request without rebuilding anything. `UserDefaults` and the Keychain are documented thread-safe, hence
/// `@unchecked Sendable`.
public final class CompanionSettingsStore: CompanionConfiguration, @unchecked Sendable {
    /// The `UserDefaults` key holding host, port and the trusted flag (never the token).
    public static let key = "ichirp.companion"
    /// The Keychain account of the pairing token.
    public static let tokenAccount = "companion.pairing-token"

    struct Stored: Codable, Equatable {
        var host: String
        var port: Int
        var trusted: Bool
    }

    private let defaults: UserDefaults
    private let secrets: any SecretStoring
    private let lock = NSLock()
    private let logger = Log.logger("companion")

    public init(defaults: UserDefaults = .standard, secrets: any SecretStoring) {
        self.defaults = defaults
        self.secrets = secrets
    }

    // MARK: - CompanionConfiguration

    public func companionEndpoint() -> CompanionEndpoint? {
        lock.withLock {
            guard let data = defaults.data(forKey: Self.key),
                let stored = try? JSONDecoder().decode(Stored.self, from: data),
                !stored.host.isEmpty
            else {
                return nil
            }
            return CompanionEndpoint(host: stored.host, port: stored.port, isTrustedForClinicalText: stored.trusted)
        }
    }

    public func companionPairingToken() throws -> SecretValue? {
        try secrets.secret(forAccount: Self.tokenAccount)
    }

    // MARK: - Editing

    /// Saves the companion. The token change is written to the Keychain first, so a failed Keychain write never
    /// leaves settings that claim a token they do not have.
    public func save(_ endpoint: CompanionEndpoint, token: APIKeyChange) throws {
        try lock.withLock {
            switch token {
            case .keep:
                break
            case .set(let secret):
                if secret.isEmpty {
                    try secrets.deleteSecret(forAccount: Self.tokenAccount)
                } else {
                    try secrets.setSecret(secret, forAccount: Self.tokenAccount)
                }
            case .remove:
                try secrets.deleteSecret(forAccount: Self.tokenAccount)
            }
            let stored = Stored(
                host: endpoint.host.trimmingCharacters(in: .whitespacesAndNewlines), port: endpoint.port,
                trusted: endpoint.isTrustedForClinicalText)
            defaults.set(try JSONEncoder().encode(stored), forKey: Self.key)
        }
        logger.info(
            "companion_saved locality=\(endpoint.locality.rawValue, privacy: .public) trusted=\(endpoint.isTrusted, privacy: .public)"
        )
    }

    /// Forgets the companion and deletes its token.
    public func remove() throws {
        try lock.withLock {
            try secrets.deleteSecret(forAccount: Self.tokenAccount)
            defaults.removeObject(forKey: Self.key)
        }
        logger.info("companion_removed")
    }

    // MARK: - Clients

    /// A client for the saved companion, or nil when none is set up or it has no token (YouTube audio needs both).
    public func makeClient() -> CompanionClient? {
        guard let endpoint = companionEndpoint(), endpoint.baseURL != nil,
            let token = try? companionPairingToken(), !token.isEmpty
        else {
            return nil
        }
        return CompanionClient(endpoint: endpoint, token: token)
    }

    /// `base` plus the companion's host when the owner trusted it and it is on the local network. Used for text sent
    /// to the companion (plan 020's voices); M4's language-model routing is unchanged.
    public func routingPolicy(adding base: PrivacyRoutingPolicy = PrivacyRoutingPolicy()) -> PrivacyRoutingPolicy {
        base.trusting(companionEndpoint())
    }
}

/// Reads "host", "host:port" or a pasted "http://host:port/…" plus a port field into a `CompanionEndpoint`.
public enum CompanionAddress {
    public enum ParseError: Error, Equatable, LocalizedError {
        case missingHost
        case invalidPort
        case notHTTP

        public var errorDescription: String? {
            switch self {
            case .missingHost: "Enter your Mac’s name (like my-mac.local) or its IP address."
            case .invalidPort: "The port is a number from 1 to 65535 (the companion uses 8765)."
            case .notHTTP: "Enter only the Mac’s name or address, without https:// (the companion speaks plain http)."
            }
        }
    }

    public static func parse(host rawHost: String, port rawPort: String, trusted: Bool) throws -> CompanionEndpoint {
        var host = rawHost.trimmingCharacters(in: .whitespacesAndNewlines)
        var port: Int?
        if host.contains("://") {
            guard let url = URL(string: host), let scheme = url.scheme?.lowercased() else {
                throw ParseError.missingHost
            }
            guard scheme == "http" else { throw ParseError.notHTTP }
            host = url.host(percentEncoded: false) ?? ""
            port = url.port
        } else if let colon = host.lastIndex(of: ":"), !host.hasSuffix("]"), host.filter({ $0 == ":" }).count == 1 {
            // "my-mac.local:8765" (an IPv6 address has several colons and is left alone).
            port = Int(host[host.index(after: colon)...])
            host = String(host[..<colon])
        }
        host = host.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard !host.isEmpty, !host.contains("/"), !host.contains(" ") else { throw ParseError.missingHost }
        let portText = rawPort.trimmingCharacters(in: .whitespacesAndNewlines)
        if !portText.isEmpty {
            guard let typed = Int(portText) else { throw ParseError.invalidPort }
            port = typed
        }
        let resolvedPort = port ?? CompanionEndpoint.defaultPort
        guard (1...65_535).contains(resolvedPort) else { throw ParseError.invalidPort }
        let endpoint = CompanionEndpoint(host: host, port: resolvedPort, isTrustedForClinicalText: trusted)
        guard endpoint.baseURL != nil else { throw ParseError.missingHost }
        return endpoint
    }
}
