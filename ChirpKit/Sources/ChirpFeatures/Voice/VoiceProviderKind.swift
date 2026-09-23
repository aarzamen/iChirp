import ChirpCore
import Foundation

/// The voices Parakeet can read with (owner's choice, design 018 §2: no Apple voices).
public enum VoiceProviderKind: String, Codable, Sendable, CaseIterable, Identifiable {
    /// The owner's voices (ChoiceVoice's Qwen3-TTS, Kokoro) on the Mac companion, over the home network.
    case companion
    /// Grok voices on xAI, over the internet.
    case xai

    public var id: String { rawValue }

    /// The engine id the plug-in reports (`ChirpEngineVoiceHTTP`); stable, never rename.
    public var engineID: String {
        switch self {
        case .companion: "companion.speech"
        case .xai: "xai.tts"
        }
    }

    public var displayName: String {
        switch self {
        case .companion: "Mac companion"
        case .xai: "Grok voices"
        }
    }

    /// Where the text goes, in plain words.
    public var place: String {
        switch self {
        case .companion: "Your Mac, over your home network"
        case .xai: "xAI, over the internet"
        }
    }

    public init?(engineID: String) {
        guard let kind = Self.allCases.first(where: { $0.engineID == engineID }) else { return nil }
        self = kind
    }
}
