import Foundation

/// The kinds of language-model providers iChirp can talk to. Each maps to one engine target
/// (`ChirpEngineAppleFM` or `ChirpEngineHTTPLLM`) and one stable `EngineDescriptor.id`.
public enum LanguageModelProviderKind: String, Codable, Sendable, CaseIterable {
    /// Apple Foundation Models, on the iPhone.
    case appleFoundationModels
    /// Anthropic Messages API.
    case anthropic
    /// OpenAI chat completions and compatible servers: OpenAI, OpenRouter, Gemini's OpenAI endpoint, LM Studio,
    /// llama.cpp server.
    case openAICompatible
    /// Ollama's native `/api/chat`.
    case ollama

    /// Stable, persisted engine id (never rename; see spec/contracts/language-model-plugin-v1.md).
    public var engineID: String {
        switch self {
        case .appleFoundationModels: "apple.foundation-models"
        case .anthropic: "http.anthropic"
        case .openAICompatible: "http.openai-compatible"
        case .ollama: "http.ollama"
        }
    }

    public var displayName: String {
        switch self {
        case .appleFoundationModels: "Apple on-device model"
        case .anthropic: "Anthropic"
        case .openAICompatible: "OpenAI-compatible"
        case .ollama: "Ollama"
        }
    }

    /// A starting base URL for the Settings form; LAN kinds need the Mac's address instead of `localhost`.
    public var suggestedBaseURL: URL? {
        switch self {
        case .appleFoundationModels: nil
        case .anthropic: URL(string: "https://api.anthropic.com/v1")
        case .openAICompatible: URL(string: "https://api.openai.com/v1")
        case .ollama: URL(string: "http://mac.local:11434")
        }
    }
}

/// One provider the user configured in Settings → Models. Holds **no secret**: the API key lives in the Keychain under
/// `secretAccount`, so encoding this value can never leak a key.
///
/// `locality` is derived from the base URL's host, never chosen by the user: only a host that is on the local network
/// (`LocalNetworkHost.isLocal`) is `.localNetwork`, and only such a host can be trusted for clinical content.
public struct LanguageModelProviderConfiguration: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var kind: LanguageModelProviderKind
    /// User-facing name, e.g. "Mac Studio (Ollama)". Shown in the clinical override confirmation.
    public var displayName: String
    /// nil for Apple Foundation Models; required for every HTTP kind.
    public var baseURL: URL?
    /// Provider model id, e.g. "claude-sonnet-4-5" or "llama3.1:8b". Empty for Apple Foundation Models.
    public var modelName: String
    /// The user marked this provider's LAN host as trusted for clinical content. Ignored unless `locality` is
    /// `.localNetwork` (a cloud host can never be trusted).
    public var trustsLocalNetworkHost: Bool
    /// Overrides the kind's default context window (tokens), e.g. the context length loaded in LM Studio.
    public var contextWindowTokens: Int?

    public init(
        id: UUID = UUID(),
        kind: LanguageModelProviderKind,
        displayName: String,
        baseURL: URL?,
        modelName: String,
        trustsLocalNetworkHost: Bool = false,
        contextWindowTokens: Int? = nil
    ) {
        self.id = id
        self.kind = kind
        self.displayName = displayName
        self.baseURL = baseURL
        self.modelName = modelName
        self.trustsLocalNetworkHost = trustsLocalNetworkHost
        self.contextWindowTokens = contextWindowTokens
    }

    /// The lowercased host content is sent to, or nil (on device, or no URL).
    public var host: String? {
        guard kind != .appleFoundationModels, let host = baseURL?.host(percentEncoded: false) else { return nil }
        let lowered = host.lowercased()
        return lowered.isEmpty ? nil : lowered
    }

    /// Where the provider runs, derived from `kind` and the base URL's host.
    public var locality: EngineLocality {
        if kind == .appleFoundationModels { return .onDevice }
        guard let host else { return .cloud }
        return LocalNetworkHost.isLocal(host) ? .localNetwork : .cloud
    }

    /// True when the user trusted this host and the host really is on the local network.
    public var isTrustedLocalNetworkHost: Bool {
        trustsLocalNetworkHost && locality == .localNetwork
    }

    /// Whether the provider needs an API key before it can run.
    public var requiresAPIKey: Bool {
        switch kind {
        case .appleFoundationModels, .ollama: false
        case .anthropic: true
        case .openAICompatible: locality == .cloud
        }
    }

    /// The Keychain account that holds this provider's API key.
    public var secretAccount: String {
        "llm.provider.\(id.uuidString.lowercased()).api-key"
    }

    public enum ValidationError: Error, Equatable, LocalizedError {
        case missingBaseURL
        case unsupportedScheme
        case credentialsInURL
        case insecureCloudURL
        case missingModelName

        public var errorDescription: String? {
            switch self {
            case .missingBaseURL: "Enter the server address, for example http://mac-studio.local:11434."
            case .unsupportedScheme: "The address must start with http:// or https://."
            case .credentialsInURL:
                "Remove the user name or password from the address; put the key in the API key field."
            case .insecureCloudURL:
                "Internet providers must use https://. Plain http:// is only allowed for a Mac on your home network."
            case .missingModelName: "Enter the model name."
            }
        }
    }

    /// Checks the form before saving. Does not touch the network.
    public func validate() throws {
        guard kind != .appleFoundationModels else { return }
        guard let baseURL, let scheme = baseURL.scheme?.lowercased(), host != nil else {
            throw ValidationError.missingBaseURL
        }
        guard scheme == "http" || scheme == "https" else { throw ValidationError.unsupportedScheme }
        guard baseURL.user(percentEncoded: false) == nil, baseURL.password(percentEncoded: false) == nil else {
            throw ValidationError.credentialsInURL
        }
        if locality == .cloud, scheme != "https" { throw ValidationError.insecureCloudURL }
        guard !modelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ValidationError.missingModelName
        }
    }
}

/// Decides whether a host name or IP literal is on the local network. Conservative on purpose: anything it does not
/// recognize is treated as the internet (`.cloud`), so a misread host can only make routing stricter.
///
/// Local: `localhost` and `*.localhost`; mDNS `*.local`; `*.home.arpa` (RFC 8375), `*.internal` (ICANN private
/// use), `*.lan`; IPv4 loopback 127/8, private 10/8, 172.16/12, 192.168/16 and link-local 169.254/16; IPv6 loopback
/// `::1`, unique-local fc00::/7 and link-local fe80::/10. Not local: single-label names (a DNS search domain can
/// expand them to a public host) and 100.64/10 (carrier-grade NAT, also used by VPN overlays).
public enum LocalNetworkHost {
    private static let localSuffixes = [".local", ".localhost", ".home.arpa", ".internal", ".lan"]

    public static func isLocal(_ rawHost: String) -> Bool {
        var host = rawHost.lowercased().trimmingCharacters(in: .whitespaces)
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        while host.hasSuffix(".") { host.removeLast() }
        guard !host.isEmpty else { return false }
        if host == "localhost" { return true }
        if let octets = ipv4Octets(host) { return isLocalIPv4(octets) }
        if host.contains(":") { return isLocalIPv6(host) }
        return localSuffixes.contains { host.hasSuffix($0) && host.count > $0.count }
    }

    private static func ipv4Octets(_ host: String) -> [Int]? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var octets: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.count <= 3, part.allSatisfy(\.isNumber), let value = Int(part), value <= 255
            else { return nil }
            octets.append(value)
        }
        return octets
    }

    private static func isLocalIPv4(_ octets: [Int]) -> Bool {
        switch (octets[0], octets[1]) {
        case (127, _), (10, _), (192, 168), (169, 254): true
        case (172, let second): (16...31).contains(second)
        default: false
        }
    }

    private static func isLocalIPv6(_ host: String) -> Bool {
        // Drop a zone index ("fe80::1%en0").
        let address = host.split(separator: "%", maxSplits: 1).first.map(String.init) ?? host
        if address == "::1" { return true }
        guard let firstGroup = address.split(separator: ":", omittingEmptySubsequences: false).first,
            !firstGroup.isEmpty, firstGroup.count <= 4, let value = UInt16(firstGroup, radix: 16)
        else { return false }
        // fc00::/7 (unique local) or fe80::/10 (link local).
        return (value & 0xFE00) == 0xFC00 || (value & 0xFFC0) == 0xFE80
    }
}

extension PrivacyRoutingPolicy {
    /// A policy that trusts, for clinical content, exactly the hosts of `providers` the user marked trusted and that
    /// really are on the local network. A cloud host is never added, whatever its flag says.
    public init(trustingLocalNetworkHostsOf providers: [LanguageModelProviderConfiguration]) {
        let hosts = providers.filter(\.isTrustedLocalNetworkHost).compactMap(\.host)
        self.init(trustedLocalNetworkHosts: Set(hosts))
    }
}
