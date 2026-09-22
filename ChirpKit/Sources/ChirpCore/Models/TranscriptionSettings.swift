/// Whether transcripts are shown as recognized or after deterministic cleanup.
public enum CleanupMode: String, Codable, Sendable, CaseIterable {
    case raw, clean
}

/// Which Parakeet TDT model generation to run. v3 is multilingual; v2 is English-only.
public enum ParakeetVariant: String, Codable, Sendable, CaseIterable {
    case v3, v2
}

/// User-facing transcription preferences.
///
/// Decoding is forgiving: a missing key or an unknown value (settings written by an older or newer build)
/// falls back to that field's default instead of discarding every saved setting.
public struct TranscriptionSettings: Codable, Sendable, Equatable {
    /// Upstream ADR-004 default.
    public var cleanupMode: CleanupMode = .raw
    /// Design canvas default.
    public var speakerLabelsEnabled: Bool = true
    public var parakeetVariant: ParakeetVariant = .v3
    public var removeUmFiller: Bool = true

    public init() {}

    public init(from decoder: any Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let value = try? container.decodeIfPresent(CleanupMode.self, forKey: .cleanupMode) {
            cleanupMode = value
        }
        if let value = try? container.decodeIfPresent(Bool.self, forKey: .speakerLabelsEnabled) {
            speakerLabelsEnabled = value
        }
        if let value = try? container.decodeIfPresent(ParakeetVariant.self, forKey: .parakeetVariant) {
            parakeetVariant = value
        }
        if let value = try? container.decodeIfPresent(Bool.self, forKey: .removeUmFiller) {
            removeUmFiller = value
        }
    }
}
