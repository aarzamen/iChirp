// Fresh implementation (M7, plan 016 Step 5; ADR-015): what Settings → Models and the Transform / Ask pickers need to
// know about small language models that run on this iPhone. The app maps its engine's catalog onto these values;
// ChirpFeatures never imports an engine target.

import ChirpCore
import Foundation

/// One small language model the app can download and run on this iPhone, as Settings → Models shows it.
public struct LocalModelOption: Sendable, Equatable, Hashable, Identifiable {
    public enum Tier: String, Sendable, Equatable, Hashable {
        /// The default: small and fast.
        case standard
        /// Better writing, more memory.
        case quality
    }

    /// Stable catalog id, persisted as the default choice (never renamed).
    public var id: String
    public var name: String
    public var tier: Tier
    /// The runtime that runs it, e.g. "llama.cpp".
    public var runtime: String
    /// SPDX id of the weights' license, e.g. "Apache-2.0".
    public var license: String
    /// Where the weights come from, e.g. "Qwen/Qwen3.5-2B · Q4_K_M".
    public var source: String
    public var downloadBytes: Int64
    /// About how much memory it needs while loaded (weights, a full window's cache, buffers).
    public var memoryBytes: Int64
    /// The window Transform and Ask budget against.
    public var contextTokens: Int

    public init(
        id: String, name: String, tier: Tier, runtime: String, license: String, source: String, downloadBytes: Int64,
        memoryBytes: Int64, contextTokens: Int
    ) {
        self.id = id
        self.name = name
        self.tier = tier
        self.runtime = runtime
        self.license = license
        self.source = source
        self.downloadBytes = downloadBytes
        self.memoryBytes = memoryBytes
        self.contextTokens = contextTokens
    }
}

/// Defaults so factories without on-device small models (test fakes) need nothing new.
extension LanguageModelFactory {
    public var localModelOptions: [LocalModelOption] { [] }
    public var localModelRuntimeProblem: String? { nil }

    public func makeLocalModel(id: String) throws -> any LanguageModel {
        throw LanguageModelError.unavailable(.notConfigured("this on-device model is not in this build"))
    }

    public func localModelAssets(id: String) -> (any ModelAssetManaging)? { nil }
}

extension LanguageModelChoice {
    /// A downloaded small model on this iPhone: on device, so clinical items may use it without a confirmation.
    public init(localModel: LocalModelOption) {
        self.init(
            source: .localModel(localModel.id), name: localModel.name, locality: .onDevice, host: nil,
            isTrustedForClinical: true)
    }
}
