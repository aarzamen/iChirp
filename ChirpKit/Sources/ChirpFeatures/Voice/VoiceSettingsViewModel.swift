// Fresh implementation for iChirp (plan 020 Step 4): Settings → Voices. Nothing here sends user text; Test voice speaks
// a fixed synthetic sentence through `VoicePlayer`, which routes like any other reading.

import ChirpCore
import Foundation
import Observation

/// Settings → Voices: which voices read aloud, the companion's voices and style, Grok's stock voices plus a free-text
/// Voice ID, the xAI key (Keychain only), and Test voice. Honest states: companion not set up / not reachable, key
/// missing.
@MainActor @Observable public final class VoiceSettingsViewModel {
    /// The Mac companion as Settings shows it.
    public enum CompanionState: Equatable {
        case checking
        case ready
        /// Not set up, not paired, not reachable, no voice model: the sentence to show.
        case unavailable(String)
    }

    /// The xAI key as Settings shows it (the key itself is never read back into the screen).
    public enum KeyState: Equatable {
        case missing
        case saved
        case checking
        case valid
        case invalid(String)
    }

    /// The fixed, synthetic sentence Test voice reads.
    public static let testSentence = "This is Parakeet, reading aloud in the voice you chose."

    public var settings: VoiceSettings {
        didSet {
            guard settings != oldValue else { return }
            store.save(settings)
        }
    }

    public private(set) var companionState: CompanionState = .checking
    public private(set) var companionVoices: [SynthesisVoice] = []
    public private(set) var keyState: KeyState = .missing
    /// The key field's text; saved to the Keychain only on `saveKey()`, then cleared.
    public var keyDraft = ""
    /// The last Keychain failure, for an alert.
    public private(set) var lastError: String?

    public let stockXAIVoices: [SynthesisVoice]

    @ObservationIgnored private let store: any VoiceSettingsStoring
    @ObservationIgnored private let secrets: any SecretStoring
    @ObservationIgnored private let engines: any VoiceEngineProviding
    @ObservationIgnored private let player: VoicePlayer

    public init(
        store: any VoiceSettingsStoring, secrets: any SecretStoring, engines: any VoiceEngineProviding,
        player: VoicePlayer, stockXAIVoices: [SynthesisVoice]
    ) {
        self.store = store
        self.secrets = secrets
        self.engines = engines
        self.player = player
        self.stockXAIVoices = stockXAIVoices
        settings = store.load()
        keyState = Self.hasKey(secrets) ? .saved : .missing
    }

    /// The name of the voice Listen uses now, for the Settings row: "Mac companion · Ryan", "Grok voices · Eve".
    public var summary: String {
        switch settings.provider {
        case nil: return "Not chosen"
        case .companion?:
            let voice =
                companionVoices.first { $0.id == settings.companionVoiceID }?.name
                ?? Self.voiceName(fromCompanionID: settings.companionVoiceID)
            return voice.isEmpty ? "Mac companion" : "Mac companion · \(voice)"
        case .xai?:
            let custom = settings.xaiCustomVoiceID.trimmingCharacters(in: .whitespacesAndNewlines)
            if !custom.isEmpty { return "Grok voices · Voice ID" }
            let name = stockXAIVoices.first { $0.id == settings.xaiStockVoiceID }?.name ?? settings.xaiStockVoiceID
            return "Grok voices · \(name)"
        }
    }

    /// Why Listen cannot read yet (nil when it can try): shown in Settings → Voices' Test voice row, and also in
    /// Create's voice-message note (`CreateSheet.swift`) where "Settings → Voices" is real navigation guidance —
    /// so this stays a standalone sentence naming where to go, rather than assuming a caller-specific "above".
    public var setupProblem: String? {
        switch settings.provider {
        case nil:
            return "Choose Mac companion or Grok voices in Settings → Voices."
        case .companion?:
            if case .unavailable(let sentence) = companionState { return sentence }
            if settings.companionVoiceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "Choose a Mac companion voice in Settings → Voices."
            }
            return nil
        case .xai?:
            if keyState == .missing { return "Add your xAI API key in Settings → Voices." }
            if case .invalid(let sentence) = keyState { return sentence }
            return nil
        }
    }

    /// Reads the companion's state and voices (no user text), and whether an xAI key is stored.
    public func refresh() async {
        if keyState == .missing || keyState == .saved {
            keyState = Self.hasKey(secrets) ? .saved : .missing
        }
        companionState = .checking
        let engine = engines.engine(for: .companion)
        switch await engine.availability() {
        case .available:
            do {
                companionVoices = try await engine.voices()
                companionState = .ready
                if settings.companionVoiceID.isEmpty, let first = companionVoices.first {
                    settings.companionVoiceID = first.id
                }
            } catch {
                companionVoices = []
                companionState = .unavailable(
                    VoicePlayer.readableMessage(for: error, engineID: VoiceProviderKind.companion.engineID))
            }
        case .unavailable(let sentence):
            companionVoices = []
            companionState = .unavailable(sentence)
        }
    }

    /// Check again: asks the companion afresh.
    public func recheckCompanion() async {
        engines.refreshCompanionAvailability()
        await refresh()
    }

    public func choose(_ provider: VoiceProviderKind) {
        settings.provider = provider
    }

    public func chooseCompanionVoice(_ id: String) {
        settings.companionVoiceID = id
    }

    /// Picking a stock voice clears a typed Voice ID, so the pick is what speaks.
    public func chooseStockXAIVoice(_ id: String) {
        settings.xaiStockVoiceID = id
        settings.xaiCustomVoiceID = ""
    }

    // MARK: - xAI key (Keychain only)

    public func saveKey() {
        let trimmed = Self.cleanedKey(keyDraft)
        guard !trimmed.isEmpty else { return }
        do {
            try secrets.setSecret(SecretValue(trimmed), forAccount: VoiceSecrets.xaiAccount)
            keyDraft = ""
            keyState = .saved
        } catch {
            lastError = "The key could not be saved in the Keychain."
        }
    }

    public func removeKey() {
        do {
            try secrets.deleteSecret(forAccount: VoiceSecrets.xaiAccount)
            keyState = .missing
        } catch {
            lastError = "The key could not be removed from the Keychain."
        }
    }

    /// Check key: `GET /v1/api-key` (nothing is spoken, no text is sent).
    public func checkKey() async {
        guard keyState != .missing else { return }
        keyState = .checking
        do {
            try await engines.validateXAIKey()
            keyState = .valid
        } catch {
            keyState = .invalid(Self.message(for: error))
        }
    }

    public func dismissError() {
        lastError = nil
    }

    // MARK: - Test voice

    /// Speaks `testSentence` (synthetic, `.general`) with the chosen voice.
    public func testVoice() async {
        await player.speak(text: Self.testSentence, privacyClass: .general, source: .voiceTest)
    }

    // MARK: - Helpers

    private static func hasKey(_ secrets: any SecretStoring) -> Bool {
        guard let stored = try? secrets.secret(forAccount: VoiceSecrets.xaiAccount) else { return false }
        return !stored.isEmpty
    }

    /// Strips what people paste around a key: spaces, quotes, `XAI_API_KEY=` and `Bearer `.
    static func cleanedKey(_ raw: String) -> String {
        var key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let equals = key.firstIndex(of: "="), key[..<equals].uppercased().contains("API_KEY") {
            key = String(key[key.index(after: equals)...])
        }
        key = key.trimmingCharacters(in: CharacterSet(charactersIn: "\"' \n\t"))
        if key.lowercased().hasPrefix("bearer ") { key = String(key.dropFirst(7)) }
        return key.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// "qwen3-tts-1.7b:Ryan" → "Ryan".
    static func voiceName(fromCompanionID id: String) -> String {
        guard let colon = id.firstIndex(of: ":") else { return id }
        return String(id[id.index(after: colon)...])
    }

    private static func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
