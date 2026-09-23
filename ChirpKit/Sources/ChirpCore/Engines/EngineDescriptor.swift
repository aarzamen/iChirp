/// What an engine does.
public enum EngineKind: String, Codable, Sendable {
    case speech, language, structure, diarization
    /// M3: speech/silence detection (Silero VAD) that cuts a meeting's live-preview chunks at pauses.
    case voiceActivity
    /// Text to speech ("Listen", read-back): spec/contracts/speech-synthesis-plugin-v1.md.
    case speechSynthesis
}

/// Where an engine runs. Privacy routing (`PrivacyRoutingPolicy`) decides per transcript which are allowed.
public enum EngineLocality: String, Codable, Sendable {
    case onDevice, localNetwork, cloud
}

/// Static facts about one engine plug-in, shown in Settings and used for routing and attribution.
public struct EngineDescriptor: Codable, Sendable, Hashable, Identifiable {
    /// Stable reverse-dotted id persisted in `Transcription.engine`, e.g. "fluidaudio.parakeet-tdt".
    public var id: String
    public var kind: EngineKind
    public var provider: String
    public var displayName: String
    public var locality: EngineLocality
    /// SPDX-style license of the model weights, e.g. "CC-BY-4.0".
    public var license: String
    public var approximateDownloadBytes: Int64?
    public var providesWordTimestamps: Bool
    /// BCP-47 language tags; empty = unknown.
    public var supportedLanguages: [String]

    public init(
        id: String,
        kind: EngineKind,
        provider: String,
        displayName: String,
        locality: EngineLocality,
        license: String,
        approximateDownloadBytes: Int64? = nil,
        providesWordTimestamps: Bool = false,
        supportedLanguages: [String] = []
    ) {
        self.id = id
        self.kind = kind
        self.provider = provider
        self.displayName = displayName
        self.locality = locality
        self.license = license
        self.approximateDownloadBytes = approximateDownloadBytes
        self.providesWordTimestamps = providesWordTimestamps
        self.supportedLanguages = supportedLanguages
    }
}
