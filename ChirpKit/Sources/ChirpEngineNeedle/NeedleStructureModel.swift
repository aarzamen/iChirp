import ChirpCore
import Foundation

/// Needle 3 behind ChirpCore's `StructureModel`: on this iPhone, CPU only, one model per process.
///
/// `extract(jsonSchema:from:privacyClass:)` takes a tool catalog (a JSON array of tool definitions) as `jsonSchema`
/// and one utterance as `text`, and returns the call array Needle chose plus the confidence head's score of that
/// answer and the model file's SHA-256. `"[]"` is Needle declining on purpose; no `<tool_call>` at all throws
/// `StructureModelError.noToolCall`.
public final class NeedleStructureModel: StructureModel, ModelAssetManaging {
    public static let engineID = "needle.needle3"

    public let descriptor = EngineDescriptor(
        id: NeedleStructureModel.engineID,
        kind: .structure,
        provider: "Cactus Compute · needle-rs",
        displayName: "Needle 3",
        locality: .onDevice,
        license: "Apache-2.0 (weights) / MIT (runtime)",
        approximateDownloadBytes: NeedleModelAssets.needle3.byteCount,
        supportedLanguages: ["en"])

    public let assets: NeedleModelAssets
    private let runtime: any NeedleInferring
    private let runtimeInBuild: Bool

    /// - Parameters:
    ///   - runtimeInBuild: whether needle-c is linked (tests pass `true` with a fake runtime).
    public init(
        assets: NeedleModelAssets, runtime: any NeedleInferring = NeedleRuntime(),
        runtimeInBuild: Bool = NeedleRuntimeInfo.isInBuild
    ) {
        self.assets = assets
        self.runtime = runtime
        self.runtimeInBuild = runtimeInBuild
    }

    /// The pinned model file's SHA-256, recorded with every result.
    public var modelSHA256: String { assets.pin.sha256 }

    /// Whether this build can run Needle at all.
    public var isRuntimeInBuild: Bool { runtimeInBuild }

    public func extract(jsonSchema: String, from text: String, privacyClass: PrivacyClass) async throws
        -> StructuredOutput
    {
        guard runtimeInBuild else { throw StructureModelError.notInThisBuild(NeedleRuntimeInfo.notInBuildMessage) }
        // Needle runs on this iPhone, so every privacy class may use it; the router still has the last word.
        guard PrivacyRoutingPolicy().allows(descriptor, for: privacyClass) else {
            throw StructureModelError.privacyRoutingRefused(descriptor.displayName)
        }
        guard await assets.isReady else { throw StructureModelError.modelNotDownloaded(descriptor.id) }
        let completion: NeedleCompletion
        do {
            try await runtime.load(modelAt: assets.modelURL)
            completion = try await runtime.complete(query: text, toolsJSON: jsonSchema)
        } catch let error as NeedleRuntimeError {
            throw error == .notInBuild
                ? StructureModelError.notInThisBuild(NeedleRuntimeInfo.notInBuildMessage)
                : StructureModelError.failed(error.errorDescription ?? "Needle failed.")
        }
        guard let payload = NeedleToolCallParser.payload(from: completion.text), !payload.isEmpty else {
            throw StructureModelError.noToolCall
        }
        return StructuredOutput(
            json: payload, confidence: min(max(completion.confidence, 0), 1), modelSHA256: modelSHA256)
    }

    public func embed(_ text: String) async throws -> [Float] {
        throw StructureModelError.unsupported("Needle 3 on needle-rs has no embedding head.")
    }

    /// Frees the loaded model (memory warning, or when the feature closes).
    public func unload() async {
        await runtime.unload()
    }

    // MARK: - ModelAssetManaging

    public func assetStatus() async -> ModelAssetStatus {
        await assets.status()
    }

    public func downloadAssets(progress: @escaping @Sendable (Double) -> Void) async throws {
        try await assets.downloadModel(progress: progress)
    }

    public func deleteAssets() async throws {
        await runtime.unload()
        try await assets.deleteModel()
    }
}

/// Registration entry point (engine plug-in rule: one per engine target).
public enum NeedleEngines {
    /// Needle 3 with its model under `<modelsDirectory>/needle3/`.
    public static func makeDefault(modelsDirectory: URL) -> NeedleStructureModel {
        NeedleStructureModel(assets: NeedleModelAssets(modelsDirectory: modelsDirectory))
    }
}
