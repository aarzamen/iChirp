import ChirpCore
import ChirpEngineLlamaCpp
import ChirpFeatures
import Foundation
import Synchronization
import UIKit

/// The app's small language models on this iPhone (M7, ADR-015): the only app code that imports
/// `ChirpEngineLlamaCpp`. It owns the process's one llama.cpp runtime and each model's file, and tells the runtime when
/// the app leaves the screen (GPU work stops there) or the system warns about memory (the model is unloaded).
/// Screens never call an engine; runs go through `DeliverableService`, Settings through `LanguageModelsViewModel`.
final class AppLocalLanguageModels: Sendable {
    let options: [LocalModelOption]
    private let engine: LlamaCppEngine
    private let assets: [String: LlamaCppModelAssets]

    /// - Parameter modelsDirectory: the folder model files live in (outside the backed-up library); each model uses
    ///   `<it>/llm/<model id>/`.
    init(modelsDirectory: URL) {
        let engine = LlamaCppModels.makeEngine()
        self.engine = engine
        var assets: [String: LlamaCppModelAssets] = [:]
        for spec in LlamaCppModels.catalog {
            assets[spec.id] = LlamaCppModels.makeAssets(for: spec, modelsDirectory: modelsDirectory, engine: engine)
        }
        self.assets = assets
        options = LlamaCppModels.isRuntimeInBuild ? LlamaCppModels.catalog.map(Self.option(for:)) : []
        #if DEBUG
        Self.debugShared.withLock { $0 = self }
        #endif
    }

    /// Why the runtime is missing from this build, or nil.
    var runtimeProblem: String? {
        LlamaCppModels.isRuntimeInBuild ? nil : LlamaCppModels.notInBuildMessage
    }

    func makeModel(id: String) throws -> any LanguageModel {
        guard let spec = LlamaCppModelCatalog.spec(id: id), let assets = assets[id] else {
            throw LanguageModelError.unavailable(.notConfigured("this on-device model is not offered any more"))
        }
        return LlamaCppModels.makeLanguageModel(spec: spec, engine: engine, assets: assets)
    }

    func modelAssets(id: String) -> (any ModelAssetManaging)? {
        LlamaCppModels.isRuntimeInBuild ? assets[id] : nil
    }

    /// Whether the model could run now (runtime, file, on screen, memory); never touches the network or loads it.
    func availability(id: String) -> LanguageModelAvailability? {
        guard let spec = LlamaCppModelCatalog.spec(id: id), let assets = assets[id] else { return nil }
        return engine.availability(for: spec, isDownloaded: assets.isReady)
    }

    /// Forwards the app's lifecycle to the runtime for the life of the process. Call once, at launch, before
    /// anything else can read `UIApplication.shared.applicationState`.
    @MainActor func observeLifecycle() {
        let center = NotificationCenter.default
        let engine = self.engine
        // A launch straight into the background (a continued-processing relaunch, a background download event) must
        // not report the models as available (review minor 2). `UIApplication.shared.applicationState` cannot tell
        // that apart from a foreground launch this early: this runs during `AppEnvironment.init`, before UIKit has
        // finished its own launch sequence, so the read is not `.background` even when the launch is (review N1).
        // Seed background and wait for the transition every launch actually posts: `willEnterForegroundNotification`
        // fires even on a fresh foreground launch, once UIKit's launch sequence reaches the active state, and the
        // observer below is registered well before then.
        engine.setForeground(false)
        _ = center.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: nil) {
            _ in
            engine.didReceiveMemoryWarning()
        }
        _ = center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil) { _ in
            engine.setForeground(false)
        }
        _ = center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: nil) { _ in
            engine.setForeground(true)
        }
        // Belt and braces for the seed above: `didBecomeActiveNotification` is posted on every foreground launch and
        // never during a background launch, so the models can never stay "backgrounded" on screen even if a launch
        // does not post `willEnterForegroundNotification`.
        _ = center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: nil) { _ in
            engine.setForeground(true)
        }
    }

    private static func option(for spec: LlamaCppModelSpec) -> LocalModelOption {
        LocalModelOption(
            id: spec.id, name: spec.displayName, tier: spec.tier == .quality ? .quality : .standard,
            runtime: "llama.cpp", license: spec.license, source: "\(spec.baseModel) · \(spec.quantization)",
            downloadBytes: spec.byteCount, memoryBytes: spec.estimatedMemoryBytes, contextTokens: spec.contextTokens,
            isMeasuredOnIPhone: spec.isMeasuredOnIPhone)
    }
}

#if DEBUG
/// DEBUG-only hooks for the on-device measurement runner (`-ChirpLLMSmoke`, review I3). Metadata only, never content.
extension AppLocalLanguageModels {
    /// The process's instance (there is one, built by `AppEnvironment`).
    static let debugShared = Mutex<AppLocalLanguageModels?>(nil)

    /// Timing of the last run, as the engine measured it.
    struct DebugRunMetrics: Sendable, Equatable {
        var modelID: String
        var loadSeconds: Double?
        var promptTokens: Int
        var completionTokens: Int
        var firstTokenSeconds: Double?
        var promptTokensPerSecond: Double
        var generationTokensPerSecond: Double
    }

    /// Whether the engine runs on the GPU in this build (false in the Simulator).
    var debugUsesGPU: Bool { LlamaCppLoader.defaultUsesGPU }

    /// Whether `observeLifecycle` currently believes the app is on screen; the app-hosted test for review N1 reads
    /// this instead of the runtime's private state.
    var debugIsForeground: Bool { engine.isForeground }

    /// Frees the loaded model, so the next run measures a cold load.
    func debugUnload() async {
        await engine.unload(reason: "measurement")
    }

    func debugLastRunMetrics() async -> DebugRunMetrics? {
        guard let metrics = await engine.lastRunMetrics else { return nil }
        return DebugRunMetrics(
            modelID: metrics.modelID, loadSeconds: metrics.loadSeconds, promptTokens: metrics.promptTokens,
            completionTokens: metrics.completionTokens, firstTokenSeconds: metrics.firstTokenSeconds,
            promptTokensPerSecond: metrics.promptTokensPerSecond,
            generationTokensPerSecond: metrics.generationTokensPerSecond)
    }
}
#endif
