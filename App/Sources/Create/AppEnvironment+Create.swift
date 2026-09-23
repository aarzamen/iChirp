import ChirpAudio
import ChirpCore
import ChirpFeatures
import Foundation

// Plan 022 (Create): factories kept out of `AppEnvironment.swift` so parallel lanes touching the composition root
// merge cleanly. Everything here is built from services the environment already owns.

extension AppEnvironment {
    /// A voice-message maker for one voice message (Step 5). Voices, routing and the stored class exactly as Listen
    /// uses them: Settings → Voices' choice, only the Mac companion's own trust, `VoiceSourcePrivacy` before every chunk.
    func makeVoiceMessageExporter() -> VoiceMessageExporter {
        let engines = voiceEngines
        let settingsStore = UserDefaultsVoiceSettingsStore()
        let companion = companionConfiguration
        let store = self.store
        let deliverableStore = self.deliverableStore
        return VoiceMessageExporter(
            selection: { try settingsStore.load().selection(engines: engines) },
            routingPolicy: { VoicePlayer.routingPolicy(companion: companion.companionEndpoint()) },
            currentPrivacyClass: { source in
                await VoiceSourcePrivacy.current(for: source, transcripts: store, deliverables: deliverableStore)
            },
            writer: VoiceMessageWriter(), paths: paths)
    }
}
