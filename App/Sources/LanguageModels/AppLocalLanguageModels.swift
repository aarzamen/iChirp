import ChirpCore
import ChirpEngineLlamaCpp
import ChirpFeatures
import Foundation
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

    /// Forwards the app's lifecycle to the runtime for the life of the process. Call once, at launch.
    @MainActor func observeLifecycle() {
        let center = NotificationCenter.default
        let engine = self.engine
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
    }

    private static func option(for spec: LlamaCppModelSpec) -> LocalModelOption {
        LocalModelOption(
            id: spec.id, name: spec.displayName, tier: spec.tier == .quality ? .quality : .standard,
            runtime: "llama.cpp", license: spec.license, source: "\(spec.baseModel) · \(spec.quantization)",
            downloadBytes: spec.byteCount, memoryBytes: spec.estimatedMemoryBytes, contextTokens: spec.contextTokens)
    }
}
