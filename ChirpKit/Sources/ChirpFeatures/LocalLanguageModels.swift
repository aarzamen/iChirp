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
    /// True once its load time, speed and peak memory on an iPhone are recorded (`scripts/device_llm_smoke.sh`, the
    /// research note). Until then Settings says "Not yet measured on iPhone" and the download asks first (review I3).
    public var isMeasuredOnIPhone: Bool

    public init(
        id: String, name: String, tier: Tier, runtime: String, license: String, source: String, downloadBytes: Int64,
        memoryBytes: Int64, contextTokens: Int, isMeasuredOnIPhone: Bool = false
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
        self.isMeasuredOnIPhone = isMeasuredOnIPhone
    }
}

/// A small model the Transform and Ask pickers show as not ready, with the reason (review I3d).
public struct UnavailableLocalModel: Sendable, Equatable, Identifiable {
    public var option: LocalModelOption
    public var reason: String
    public var id: String { option.id }
}

/// Whether a model's documented memory fits what iOS lets Parakeet use right now (`os_proc_available_memory`).
public enum LocalModelFit: Sendable, Equatable {
    /// The system does not say (the Simulator, the Mac).
    case unknown
    case fits(availableBytes: UInt64)
    case doesNotFit(availableBytes: UInt64)

    public static func check(memoryBytes: Int64, availableBytes: UInt64?) -> LocalModelFit {
        guard let availableBytes else { return .unknown }
        return availableBytes >= UInt64(max(memoryBytes, 0))
            ? .fits(availableBytes: availableBytes) : .doesNotFit(availableBytes: availableBytes)
    }
}

/// What Settings asks before a small-model download (review I3c): size, memory fit, measurement.
public struct LocalModelDownloadNotice: Sendable, Equatable {
    public var title: String
    public var message: String
    /// "Download", or "Download Anyway" when the model would not fit now.
    public var confirmTitle: String
    public var fit: LocalModelFit
}

extension LocalModelOption {
    /// Downloads larger than this always ask first, with the size.
    public static let largeDownloadBytes: Int64 = 1_000_000_000

    /// Until the model is measured on an iPhone: a plain line, stronger for the quality tier.
    public var measurementCaution: String? {
        guard !isMeasuredOnIPhone else { return nil }
        switch tier {
        case .standard:
            return "Not yet measured on iPhone: its speed and memory on a phone are not known yet."
        case .quality:
            return "Not yet measured on iPhone. At about \(Self.gigabytes(memoryBytes)) of memory it may not fit next "
                + "to Parakeet's speech models, and iOS can close Parakeet in the middle of a note. Try the standard "
                + "model first."
        }
    }

    /// The question before the download, or nil when none is needed (1 GB or less, fits, measured).
    public func downloadNotice(availableMemoryBytes: UInt64?) -> LocalModelDownloadNotice? {
        let fit = LocalModelFit.check(memoryBytes: memoryBytes, availableBytes: availableMemoryBytes)
        let doesNotFit: Bool
        if case .doesNotFit = fit { doesNotFit = true } else { doesNotFit = false }
        guard downloadBytes > Self.largeDownloadBytes || doesNotFit || !isMeasuredOnIPhone else { return nil }

        var lines = [
            "About \(Self.gigabytes(downloadBytes)) from Hugging Face, kept on this iPhone; use Wi-Fi."
        ]
        let needs = "It needs about \(Self.gigabytes(memoryBytes)) of memory while it writes"
        switch fit {
        case .unknown:
            lines.append(needs + ".")
        case .fits(let available):
            lines.append(needs + "; Parakeet can use about \(Self.gigabytes(Int64(clamping: available))) right now.")
        case .doesNotFit(let available):
            lines.append(
                needs + ", but Parakeet can use only about \(Self.gigabytes(Int64(clamping: available))) right now, "
                    + "so it will probably not run on this iPhone.")
        }
        if let measurementCaution { lines.append(measurementCaution) }
        return LocalModelDownloadNotice(
            title: "Download \(name)?", message: lines.joined(separator: "\n\n"),
            confirmTitle: doesNotFit ? "Download Anyway" : "Download", fit: fit)
    }

    /// "1.3 GB" (decimal, as storage is sold); "800 MB" below a gigabyte.
    static func gigabytes(_ bytes: Int64) -> String {
        bytes >= 1_000_000_000
            ? String(format: "%.1f GB", Double(bytes) / 1_000_000_000)
            : "\(Int((Double(bytes) / 1_000_000).rounded())) MB"
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

    public func localModelAvailability(id: String) async -> LanguageModelAvailability? { nil }
}

extension LanguageModelChoice {
    /// A downloaded small model on this iPhone: on device, so clinical items may use it without a confirmation.
    public init(localModel: LocalModelOption) {
        self.init(
            source: .localModel(localModel.id), name: localModel.name, locality: .onDevice, host: nil,
            isTrustedForClinical: true)
    }
}
