// Fresh implementation (M7, plan 016 Step 5; ADR-015): small language models on the iPhone through llama.cpp, behind
// ChirpCore's `LanguageModel` (spec/contracts/language-model-plugin-v1.md).

import ChirpCore
import Foundation

/// One downloadable small model running on this iPhone (llama.cpp, GPU). Content never leaves the device, so every
/// privacy class may use it; routing still goes through `PrivacyRoutingPolicy` in `DeliverableService`.
///
/// - `availability()` never touches the network: runtime in the build, model downloaded, app on screen, enough memory.
/// - `contextWindowTokens()` is the window iChirp allocates for the model (not the model's trained maximum), so the
///   map-reduce planner budgets against what really fits.
/// - `generate` streams text deltas, then usage, then `.finished`; cancelling the consumer stops decoding within one
///   token (or one 512-token batch while reading the prompt).
public struct LlamaCppLanguageModel: LanguageModel {
    /// Stable, persisted engine id (never rename). The model is recorded separately (`GenerationUsage.model`).
    public static let engineID = "llamacpp.gguf"

    public let spec: LlamaCppModelSpec
    public let descriptor: EngineDescriptor
    private let engine: LlamaCppEngine
    private let assets: LlamaCppModelAssets

    public init(spec: LlamaCppModelSpec, engine: LlamaCppEngine, assets: LlamaCppModelAssets) {
        self.spec = spec
        self.engine = engine
        self.assets = assets
        descriptor = EngineDescriptor(
            id: Self.engineID,
            kind: .language,
            provider: "llama.cpp",
            displayName: spec.displayName,
            locality: .onDevice,
            license: "\(spec.license) (\(spec.baseModel) weights); llama.cpp MIT",
            approximateDownloadBytes: spec.byteCount)
    }

    public var endpointHost: String? { nil }

    public func contextWindowTokens() async -> Int? { spec.contextTokens }

    public func availability() async -> LanguageModelAvailability {
        engine.availability(for: spec, isDownloaded: assets.isReady)
    }

    public func generate(_ request: GenerationRequest) -> AsyncThrowingStream<GenerationEvent, Error> {
        let spec = self.spec
        let engine = self.engine
        let assets = self.assets
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    if case .unavailable(let reason) = engine.availability(for: spec, isDownloaded: assets.isReady) {
                        throw LanguageModelError.unavailable(reason)
                    }
                    let usage = try await engine.run(spec: spec, modelURL: assets.modelURL, request: request) { text in
                        continuation.yield(.text(text))
                    }
                    continuation.yield(.usage(usage))
                    continuation.yield(.finished)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Self.map(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Mapping (internal for tests)

    static func map(_ error: Error) -> Error {
        if error is CancellationError || error is LanguageModelError { return error }
        if error is LlamaCppEngineError { return LanguageModelError.unavailable(reason(for: error)) }
        switch error as? LlamaSessionError {
        case .notInBuild?:
            return LanguageModelError.unavailable(reason(for: LlamaCppEngineError.notInBuild))
        case .loadFailed(let detail)?:
            return LanguageModelError.providerError("the on-device model could not be loaded (\(detail)).")
        case .tokenizeFailed?:
            return LanguageModelError.providerError("the on-device model could not read the text.")
        case .decodeFailed(let code)?:
            return LanguageModelError.providerError("the on-device model stopped (llama.cpp code \(code)).")
        case nil:
            return LanguageModelError.providerError(
                "the on-device model failed (\(String(describing: type(of: error)))).")
        }
    }

    static func reason(for error: Error) -> LanguageModelUnavailableReason {
        switch error as? LlamaCppEngineError {
        case .notInBuild?:
            return .other(LlamaCppRuntimeInfo.notInBuildMessage)
        case .notDownloaded(let name)?:
            return .notConfigured("download \(name) in Settings → Models.")
        case .inBackground?:
            return .other("on-device models run only while Parakeet is on screen. Keep it open until the text is done.")
        case .notEnoughMemory(let name, let needed, let available)?:
            return .other(
                "\(name) needs about \(gigabytes(needed)) of memory and Parakeet can use about "
                    + "\(gigabytes(Int64(clamping: available))) right now. Close other apps, or pick a smaller model.")
        case nil:
            return .other("the on-device model cannot run right now.")
        }
    }

    static func gigabytes(_ bytes: Int64) -> String {
        String(format: "%.1f GB", Double(bytes) / 1_000_000_000)
    }
}

/// Registration entry point (ADR-004): the catalog, the one engine of the process, each model's file, the engines.
public enum LlamaCppModels {
    public static var isRuntimeInBuild: Bool { LlamaCppRuntimeInfo.isInBuild }
    public static var notInBuildMessage: String { LlamaCppRuntimeInfo.notInBuildMessage }
    public static let catalog = LlamaCppModelCatalog.all

    /// The process's one llama.cpp runtime (GPU on a device, CPU in the Simulator).
    public static func makeEngine() -> LlamaCppEngine {
        LlamaCppEngine()
    }

    /// A model's file under `<modelsDirectory>/llm/<id>/`; deleting it first unloads the model from `engine`.
    public static func makeAssets(for spec: LlamaCppModelSpec, modelsDirectory: URL, engine: LlamaCppEngine)
        -> LlamaCppModelAssets
    {
        LlamaCppModelAssets(
            spec: spec, modelsDirectory: modelsDirectory,
            willDelete: { await engine.release(modelID: spec.id) })
    }

    public static func makeLanguageModel(
        spec: LlamaCppModelSpec, engine: LlamaCppEngine, assets: LlamaCppModelAssets
    ) -> LlamaCppLanguageModel {
        LlamaCppLanguageModel(spec: spec, engine: engine, assets: assets)
    }
}
