import ChirpCore
import Foundation

/// The registration entry point: the app builds its voice engines here and sees them only as `SpeechSynthesizing`.
public enum VoiceEngines {
    /// Grok voices (xAI). The key is read from `secrets` at every call, so saving a new key needs no rebuild.
    public static func makeXAI(secrets: any SecretStoring) -> XAIVoice {
        XAIVoice(secrets: secrets)
    }

    /// The owner's voices on the Mac companion. Reads the address and pairing token at every call; `pinned()` binds
    /// one utterance to the host routing approved.
    public static func makeCompanion(configuration: any CompanionConfiguration) -> CompanionVoice {
        CompanionVoice(configuration: configuration)
    }

    /// Checks the stored xAI key (`GET /v1/api-key`): no text is sent and nothing is spoken.
    public static func validateXAIKey(secrets: any SecretStoring) async throws {
        try await XAIVoice(secrets: secrets).validateKey()
    }
}
