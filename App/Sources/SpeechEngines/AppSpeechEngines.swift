import ChirpCore
import ChirpEngineFluidAudio
import ChirpFeatures
import Foundation

/// M7: every speech engine in this build behind one `SpeechEngineRouter` (plan 016). Parakeet is first: it is the
/// default for both routes and the fallback when a saved choice is not in this build.
enum AppSpeechEngines {
    static func makeRouter(parakeet: ParakeetEngine, store: any SpeechRouteStoring) -> SpeechEngineRouter {
        let engines: [SpeechEngineRouter.Registration] = [
            .init(
                key: SpeechEngineVariantKey(engineID: ParakeetEngine.engineID, variant: parakeet.variant.rawValue),
                engine: parakeet)
        ]
        return SpeechEngineRouter(engines: engines, selection: store.load(), onSelectionChange: { store.save($0) })
    }
}
