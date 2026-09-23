import ChirpCore
import ChirpEngineVoiceHTTP
import ChirpFeatures
import Foundation

/// The app's engine registration for voices (plan 020): the only app code that imports `ChirpEngineVoiceHTTP`.
/// Screens never call an engine; they go through `VoicePlayer` (which routes) and `VoiceSettingsViewModel`.
@MainActor
final class AppVoiceEngines: VoiceEngineProviding {
    private let secrets: any SecretStoring
    private let companionEngine: CompanionVoice
    private let xaiEngine: XAIVoice

    init(secrets: any SecretStoring, companion: any CompanionConfiguration) {
        self.secrets = secrets
        companionEngine = VoiceEngines.makeCompanion(configuration: companion)
        xaiEngine = VoiceEngines.makeXAI(secrets: secrets)
    }

    func engine(for kind: VoiceProviderKind) -> any SpeechSynthesizing {
        switch kind {
        case .companion: companionEngine
        case .xai: xaiEngine
        }
    }

    /// The companion is pinned to its address and token as they are now, so one reading keeps talking to the host
    /// routing approved; xAI's host never changes.
    func engineForUtterance(_ kind: VoiceProviderKind) throws -> any SpeechSynthesizing {
        switch kind {
        case .companion: try companionEngine.pinned()
        case .xai: xaiEngine
        }
    }

    func validateXAIKey() async throws {
        try await VoiceEngines.validateXAIKey(secrets: secrets)
    }

    func refreshCompanionAvailability() {
        companionEngine.invalidateAvailability()
    }
}
