import ChirpCore
import ChirpEngineAppleSpeech
import ChirpEngineFluidAudio
import ChirpEngineWhisperKit
import ChirpFeatures
import Foundation

/// M7: every speech engine in this build behind one `SpeechEngineRouter` (plan 016). Parakeet is first: it is the
/// default for both routes and the fallback when a saved choice is not in this build.
enum AppSpeechEngines {
    /// - Parameter modelsDirectory: the app's `Models` folder next to the library (not backed up); WhisperKit keeps its
    ///   downloads in `WhisperKit/` inside it.
    static func makeRouter(
        parakeet: ParakeetEngine, modelsDirectory: URL, store: any SpeechRouteStoring
    ) -> SpeechEngineRouter {
        var engines: [SpeechEngineRouter.Registration] = [
            .init(
                key: SpeechEngineVariantKey(engineID: ParakeetEngine.engineID, variant: parakeet.variant.rawValue),
                engine: parakeet),
            // Step 2: iOS's own SpeechTranscriber (models managed by iOS; unavailable in the Simulator).
            .init(
                key: SpeechEngineVariantKey(engineID: AppleSpeechEngine.engineID),
                engine: AppleSpeechEngines.makeDefault()),
        ]
        // Step 4: WhisperKit base and large-v3 turbo (explicit downloads; Whisper large-v3 stays a marked registry row).
        let whisperFolder = modelsDirectory.appendingPathComponent("WhisperKit", isDirectory: true)
        for engine in WhisperKitEngines.makeDefault(modelsDirectory: whisperFolder) {
            engines.append(
                .init(
                    key: SpeechEngineVariantKey(engineID: WhisperKitEngine.engineID, variant: engine.variant.rawValue),
                    engine: engine))
        }
        return SpeechEngineRouter(engines: engines, selection: store.load(), onSelectionChange: { store.save($0) })
    }
}
