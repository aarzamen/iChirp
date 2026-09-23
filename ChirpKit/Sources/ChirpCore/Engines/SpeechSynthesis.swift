import Foundation

// Contract: spec/contracts/speech-synthesis-plugin-v1.md. Semantics from Readback (the owner's macOS read-aloud app):
// Sources/TTS/TTSProvider.swift. Conformers live in ChirpEngineVoiceHTTP (Mac companion, xAI).

/// One voice an engine offers. `id` is what the provider expects (an xAI voice id, a Qwen3-TTS speaker name, a
/// Kokoro voice); `name` and `detail` are for the picker.
public struct SynthesisVoice: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    /// A short description, e.g. "Dynamic male, strong rhythmic drive (US)".
    public var detail: String?
    /// BCP-47 tags the voice speaks; empty = unknown.
    public var languages: [String]

    public init(id: String, name: String, detail: String? = nil, languages: [String] = []) {
        self.id = id
        self.name = name
        self.detail = detail
        self.languages = languages
    }
}

/// One synthesis call: one chunk of text (callers split long text; see `maxCharactersPerRequest`).
public struct SynthesisRequest: Sendable, Equatable {
    public var text: String
    public var voiceID: String
    /// A free-text delivery instruction where the provider supports one (Qwen3-TTS "style"), e.g. "calm and slow".
    public var style: String?
    /// BCP-47 language, or nil for the provider's automatic choice.
    public var language: String?
    /// Neighbouring text for providers that smooth prosody across chunks; never spoken.
    public var previousText: String?
    public var nextText: String?
    /// Routing input: the caller must only hand this request to an engine `PrivacyRoutingPolicy` allows.
    public var privacyClass: PrivacyClass

    public init(
        text: String, voiceID: String, style: String? = nil, language: String? = nil, previousText: String? = nil,
        nextText: String? = nil, privacyClass: PrivacyClass
    ) {
        self.text = text
        self.voiceID = voiceID
        self.style = style
        self.language = language
        self.previousText = previousText
        self.nextText = nextText
        self.privacyClass = privacyClass
    }
}

/// Encoded audio for one chunk.
public struct SynthesizedAudio: Sendable, Equatable {
    public enum Format: String, Codable, Sendable { case mp3, wav, aac }
    public var data: Data
    public var format: Format

    public init(data: Data, format: Format) {
        self.data = data
        self.format = format
    }
}

/// Whether a voice engine can run right now, checked before any text is handed to it.
public enum SpeechSynthesisAvailability: Sendable, Equatable {
    case available
    /// A user-facing sentence, e.g. "The Mac companion is not reachable on this network."
    case unavailable(String)
}

/// A text-to-speech engine plug-in (home network or cloud).
public protocol SpeechSynthesizing: Sendable {
    var descriptor: EngineDescriptor { get }
    /// The host text is sent to, for routing (`PrivacyRoutingPolicy.allows(_:for:host:userOverride:)`); nil on device.
    var endpointHost: String? { get }
    /// The longest text one `synthesize` call accepts; callers chunk above it.
    var maxCharactersPerRequest: Int { get }
    func availability() async -> SpeechSynthesisAvailability
    func voices() async throws -> [SynthesisVoice]
    func synthesize(_ request: SynthesisRequest) async throws -> SynthesizedAudio
}

/// Errors every voice engine maps onto. Associated strings may echo request text: show them on the device, never
/// log or store them (use `kindName`).
public enum SpeechSynthesisError: Error, Sendable, Equatable, LocalizedError {
    case notConfigured(String)
    case unauthorized
    case rateLimited
    case server(status: Int, message: String)
    case connectionFailed(String)
    /// A redirect was refused: text is only ever sent to the configured host.
    case redirectRefused
    case unsupportedVoice(String)
    case emptyAudio
    /// `PrivacyRoutingPolicy` refused this engine for the item's privacy class.
    case privacyRefused

    public var kindName: String {
        switch self {
        case .notConfigured: "not_configured"
        case .unauthorized: "unauthorized"
        case .rateLimited: "rate_limited"
        case .server: "server"
        case .connectionFailed: "connection_failed"
        case .redirectRefused: "redirect_refused"
        case .unsupportedVoice: "unsupported_voice"
        case .emptyAudio: "empty_audio"
        case .privacyRefused: "privacy_refused"
        }
    }

    public var errorDescription: String? {
        switch self {
        case .notConfigured(let detail): "This voice is not set up yet: \(detail)"
        case .unauthorized: "The voice provider rejected the key. Check it in Settings → Voices."
        case .rateLimited: "The voice provider is rate-limiting requests. Wait a moment and try again."
        case .server(let status, let message):
            message.isEmpty
                ? "The voice provider returned an error (\(status))." : "Voice provider error \(status): \(message)"
        case .connectionFailed(let detail): "Could not reach the voice provider: \(detail)"
        case .redirectRefused: "The server tried to redirect the request elsewhere, so nothing was sent."
        case .unsupportedVoice(let id): "This provider has no voice \"\(id)\"."
        case .emptyAudio: "The voice provider returned no audio."
        case .privacyRefused: "This item's privacy class does not allow that voice provider."
        }
    }
}
