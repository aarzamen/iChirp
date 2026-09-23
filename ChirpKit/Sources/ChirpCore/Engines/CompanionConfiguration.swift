import Foundation

// Contract: spec/contracts/mac-companion-v1.md. Plan 020 reads the companion's address and pairing token through this
// protocol; plan 019's Settings → Mac companion store is the real conformer (host, port, Keychain token, trusted).

/// Where the owner's Mac companion listens, and whether the owner trusts it with clinical text.
public struct CompanionEndpoint: Sendable, Equatable {
    public static let defaultPort = 8765

    /// "studio.local" or "192.168.1.20", as the owner typed it.
    public var host: String
    public var port: Int
    /// The owner marked this Mac trusted for clinical text. Counts only while the host is on the local network.
    public var isTrustedForClinicalText: Bool

    public init(host: String, port: Int = CompanionEndpoint.defaultPort, isTrustedForClinicalText: Bool = false) {
        self.host = host
        self.port = port
        self.isTrustedForClinicalText = isTrustedForClinicalText
    }

    /// The lowercased host without spaces, brackets or a trailing dot: what routing compares.
    public var normalizedHost: String {
        var value = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.hasPrefix("["), value.hasSuffix("]") { value = String(value.dropFirst().dropLast()) }
        while value.hasSuffix(".") { value.removeLast() }
        return value
    }

    /// `.localNetwork` for a host on the home network (`LocalNetworkHost.isLocal`), otherwise `.cloud`: an address on
    /// the internet is treated like any cloud service, whatever it is called.
    public var locality: EngineLocality {
        LocalNetworkHost.isLocal(normalizedHost) ? .localNetwork : .cloud
    }

    /// True when the owner trusted it and it really is on the local network.
    public var isTrusted: Bool {
        isTrustedForClinicalText && locality == .localNetwork
    }

    /// `http://<host>:<port>` (IPv6 in brackets), or nil when the host or port cannot form a URL.
    public var baseURL: URL? {
        let host = normalizedHost
        guard !host.isEmpty, (1...65_535).contains(port) else { return nil }
        var components = URLComponents()
        components.scheme = "http"
        components.host = host.contains(":") ? "[\(host)]" : host
        components.port = port
        return components.url
    }
}

/// The companion's configuration, read at every call (the owner can change it any time).
public protocol CompanionConfiguration: Sendable {
    /// nil when the owner has not set up a companion.
    func companionEndpoint() -> CompanionEndpoint?
    /// The pairing token (Keychain), or nil when the phone is not paired.
    func companionPairingToken() throws -> SecretValue?
}

/// A fixed configuration: an engine bound to it keeps talking to exactly this host for one utterance.
public struct FixedCompanionConfiguration: CompanionConfiguration {
    public let endpoint: CompanionEndpoint?
    public let token: SecretValue?

    public init(endpoint: CompanionEndpoint?, token: SecretValue?) {
        self.endpoint = endpoint
        self.token = token
    }

    public func companionEndpoint() -> CompanionEndpoint? { endpoint }
    public func companionPairingToken() throws -> SecretValue? { token }
}

extension PrivacyRoutingPolicy {
    /// Also trusts the companion's host when the owner marked it trusted and it is on the local network.
    public func trusting(_ companion: CompanionEndpoint?) -> PrivacyRoutingPolicy {
        guard let companion, companion.isTrusted else { return self }
        var policy = self
        policy.trustedLocalNetworkHosts.insert(companion.normalizedHost)
        return policy
    }
}
