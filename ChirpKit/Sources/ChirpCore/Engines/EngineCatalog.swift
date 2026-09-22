/// Decides whether an engine may process content of a given `PrivacyClass`.
///
/// - `.general` and `.personal`: every locality is allowed.
/// - `.clinical`: `.onDevice` is allowed; `.localNetwork` only when `host` is in `trustedLocalNetworkHosts`
///   (case-insensitive) or `userOverride` is true; `.cloud` only when `userOverride` is true.
public struct PrivacyRoutingPolicy: Sendable {
    /// LAN hosts (e.g. "mac-studio.local") the user has marked as trusted for clinical content.
    public var trustedLocalNetworkHosts: Set<String> = []

    public init(trustedLocalNetworkHosts: Set<String> = []) {
        self.trustedLocalNetworkHosts = trustedLocalNetworkHosts
    }

    /// .clinical → only .onDevice (or .localNetwork when `host` is trusted); cloud requires `userOverride == true`.
    public func allows(
        _ descriptor: EngineDescriptor,
        for privacy: PrivacyClass,
        host: String? = nil,
        userOverride: Bool = false
    ) -> Bool {
        switch privacy {
        case .general, .personal:
            return true
        case .clinical:
            switch descriptor.locality {
            case .onDevice:
                return true
            case .localNetwork:
                return userOverride || isTrusted(host)
            case .cloud:
                return userOverride
            }
        }
    }

    private func isTrusted(_ host: String?) -> Bool {
        guard let host = host?.lowercased(), !host.isEmpty else { return false }
        return trustedLocalNetworkHosts.contains { $0.lowercased() == host }
    }
}
