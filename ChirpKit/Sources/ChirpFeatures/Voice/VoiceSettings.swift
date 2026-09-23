import ChirpCore
import Foundation

/// Settings → Voices. Holds **no secret** (the xAI key lives in the Keychain). Voice ids the owner types, such as a
/// cloned xAI voice, are stored here on the device and never in the repository (speech-synthesis-plugin-v1 rule 3).
public struct VoiceSettings: Codable, Sendable, Equatable {
    /// Which voices read aloud; nil until the owner picks one.
    public var provider: VoiceProviderKind?
    /// A companion voice id from `GET /v1/voices`, e.g. "qwen3-tts-1.7b:Ryan".
    public var companionVoiceID: String
    /// A delivery instruction for voices that take one (Qwen3-TTS), e.g. "calm and slow".
    public var companionStyle: String
    /// One of xAI's stock voices.
    public var xaiStockVoiceID: String
    /// A voice id typed on the phone (a cloned voice in the owner's xAI account). Wins over the stock voice.
    public var xaiCustomVoiceID: String
    /// Ask reads each answer aloud when it arrives.
    public var speakAskAnswers: Bool

    public init(
        provider: VoiceProviderKind? = nil, companionVoiceID: String = "", companionStyle: String = "",
        xaiStockVoiceID: String = "eve", xaiCustomVoiceID: String = "", speakAskAnswers: Bool = false
    ) {
        self.provider = provider
        self.companionVoiceID = companionVoiceID
        self.companionStyle = companionStyle
        self.xaiStockVoiceID = xaiStockVoiceID
        self.xaiCustomVoiceID = xaiCustomVoiceID
        self.speakAskAnswers = speakAskAnswers
    }

    /// The xAI voice sent: the typed Voice ID when there is one, else the stock voice.
    public var effectiveXAIVoiceID: String {
        let custom = xaiCustomVoiceID.trimmingCharacters(in: .whitespacesAndNewlines)
        return custom.isEmpty ? xaiStockVoiceID : custom
    }

    /// Forgiving: a missing or unreadable field keeps its default.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = VoiceSettings()
        provider = (try? container.decodeIfPresent(VoiceProviderKind.self, forKey: .provider)) ?? defaults.provider
        companionVoiceID = (try? container.decodeIfPresent(String.self, forKey: .companionVoiceID)) ?? ""
        companionStyle = (try? container.decodeIfPresent(String.self, forKey: .companionStyle)) ?? ""
        xaiStockVoiceID =
            (try? container.decodeIfPresent(String.self, forKey: .xaiStockVoiceID)) ?? defaults.xaiStockVoiceID
        xaiCustomVoiceID = (try? container.decodeIfPresent(String.self, forKey: .xaiCustomVoiceID)) ?? ""
        speakAskAnswers = (try? container.decodeIfPresent(Bool.self, forKey: .speakAskAnswers)) ?? false
    }
}

/// Where `VoiceSettings` live.
public protocol VoiceSettingsStoring: Sendable {
    func load() -> VoiceSettings
    func save(_ settings: VoiceSettings)
}

/// `VoiceSettingsStoring` as one JSON blob in `UserDefaults` (never a key). `UserDefaults` is thread-safe.
public final class UserDefaultsVoiceSettingsStore: VoiceSettingsStoring, @unchecked Sendable {
    public static let key = "ichirp.voiceSettings"

    private let defaults: UserDefaults
    private let logger = Log.logger("voice-settings")

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> VoiceSettings {
        guard let data = defaults.data(forKey: Self.key) else { return VoiceSettings() }
        do {
            return try JSONDecoder().decode(VoiceSettings.self, from: data)
        } catch {
            logger.error("voice_settings_decode_failed; using defaults")
            return VoiceSettings()
        }
    }

    public func save(_ settings: VoiceSettings) {
        do {
            defaults.set(try JSONEncoder().encode(settings), forKey: Self.key)
        } catch {
            logger.error("voice_settings_encode_failed error_type=\(error.logTypeName, privacy: .public)")
        }
    }
}

/// The voice engines, as the app builds them over `ChirpEngineVoiceHTTP` (the only code that imports it). Tests use
/// a fake.
@MainActor
public protocol VoiceEngineProviding: AnyObject {
    /// The live engine (reads its configuration at every call): Settings' voice list and availability.
    func engine(for kind: VoiceProviderKind) -> any SpeechSynthesizing
    /// The engine one utterance speaks with, bound to the configuration as it is now (the companion's host and
    /// token). Throws `SpeechSynthesisError.notConfigured` when it is not set up.
    func engineForUtterance(_ kind: VoiceProviderKind) throws -> any SpeechSynthesizing
    /// Settings' Check key: `GET /v1/api-key` with the stored xAI key (no text, nothing spoken).
    func validateXAIKey() async throws
    /// Settings' Check again: forget the companion's cached health answer.
    func refreshCompanionAvailability()
}

/// The Keychain account of each provider's secret. The companion's pairing token belongs to plan 019's store.
public enum VoiceSecrets {
    /// Must equal `ChirpEngineVoiceHTTP.XAIVoice.secretAccount` (AppTests checks it).
    public static let xaiAccount = "voice.xai.api-key"
}

extension VoiceSettings {
    /// What one utterance speaks with, from these settings. Throws a `notConfigured` sentence when a choice is
    /// missing; sends nothing.
    @MainActor
    public func selection(engines: any VoiceEngineProviding) throws -> VoiceSelection {
        switch provider {
        case nil:
            throw SpeechSynthesisError.notConfigured("choose Mac companion or Grok voices in Settings → Voices.")
        case .companion?:
            let voice = companionVoiceID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !voice.isEmpty else {
                throw SpeechSynthesisError.notConfigured("choose a Mac companion voice in Settings → Voices.")
            }
            let style = companionStyle.trimmingCharacters(in: .whitespacesAndNewlines)
            return VoiceSelection(
                engine: try engines.engineForUtterance(.companion), voiceID: voice,
                style: style.isEmpty ? nil : style)
        case .xai?:
            let voice = effectiveXAIVoiceID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !voice.isEmpty else {
                throw SpeechSynthesisError.notConfigured("choose a Grok voice in Settings → Voices.")
            }
            return VoiceSelection(engine: try engines.engineForUtterance(.xai), voiceID: voice)
        }
    }
}
