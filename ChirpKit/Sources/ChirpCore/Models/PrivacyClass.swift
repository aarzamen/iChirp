/// How sensitive a transcript is. Drives which engines may process it (see `PrivacyRoutingPolicy`).
///
/// - `general`: nothing personal; any engine.
/// - `personal`: the default for new rows; any engine the user has enabled.
/// - `clinical`: PHI-bearing; on-device only unless a trusted LAN host or an explicit user override.
public enum PrivacyClass: String, Codable, Sendable, CaseIterable {
    case general, personal, clinical
}
