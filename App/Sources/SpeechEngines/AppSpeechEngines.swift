import ChirpCore
import ChirpEngineAppleSpeech
import ChirpEngineFluidAudio
import ChirpEngineWhisperKit
import ChirpFeatures
import ChirpAudio
import Foundation
import UIKit

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

    /// M7 Step 6: Settings → Speech engines → Benchmark, on the app's scheduler (one job at a time with everything
    /// else), the bundled reference set and this device's memory probe.
    @MainActor static func makeBenchmark(
        router: SpeechEngineRouter, scheduler: SpeechJobScheduler, paths: AppPaths
    ) -> ASRBenchmarkViewModel {
        let runner = ASRBenchmarkRunner(
            scheduler: scheduler, normalizer: AVAudioNormalizer(), memory: { MemoryProbe.physicalFootprintBytes() })
        let referenceFolder = Bundle.main.resourceURL.flatMap {
            FileManager.default.fileExists(
                atPath: $0.appendingPathComponent(ASRBenchmarkReferenceSet.manifestName).path)
                ? $0 : nil
        }
        return ASRBenchmarkViewModel(
            router: router, runner: runner, store: .appDefault(paths: paths), referenceFolder: referenceFolder,
            importFolder: FileManager.default.temporaryDirectory.appendingPathComponent(
                "benchmark-imports", isDirectory: true),
            device: deviceDescription(), appBuild: BuildIdentity.current.summary)
    }

    /// "iPhone18,1 · iOS 26.2" (the model identifier; "Simulator" in the Simulator).
    @MainActor static func deviceDescription() -> String {
        var system = utsname()
        uname(&system)
        let machine = withUnsafeBytes(of: &system.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        #if targetEnvironment(simulator)
        let model = "Simulator (\(machine))"
        #else
        let model = machine
        #endif
        return "\(model) · iOS \(UIDevice.current.systemVersion)"
    }
}
