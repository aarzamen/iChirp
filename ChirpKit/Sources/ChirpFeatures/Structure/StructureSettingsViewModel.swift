import ChirpCore
import Foundation
import Observation

/// Review L3 I10: Needle is **experimental** until its argument accuracy on `soap-meds.v1` reaches ADR-012's 0.9 bar.
/// The numbers are the latest real eval (`docs/research/2026-09-22-needle-eval.md`); update them together with that
/// file after every eval run. Every screen where Needle is used shows `chip` or `sentence`.
public enum NeedleExperimental {
    /// Needle 3, normalizer on: argument accuracy on the synthetic SOAP set.
    public static let measuredArgumentAccuracy = 0.446
    /// Needle 3: voice-command feature accuracy (phrase check and engine) on the synthetic command set.
    public static let measuredCommandAccuracy = 0.567
    public static let bar = 0.9
    public static var isExperimental: Bool { measuredArgumentAccuracy < bar }

    static func percent(_ value: Double) -> String { "\(Int((value * 100).rounded()))%" }

    /// "Experimental · 45% argument accuracy (synthetic eval)"
    public static var chip: String {
        "Experimental · \(percent(measuredArgumentAccuracy)) argument accuracy (synthetic eval)"
    }
    /// For voice commands.
    public static var commandChip: String {
        "Experimental · \(percent(measuredCommandAccuracy)) command accuracy (synthetic eval)"
    }
    public static var sentence: String {
        "Experimental: Needle 3 got \(percent(measuredArgumentAccuracy)) of arguments right on the synthetic eval set "
            + "(the bar is \(percent(bar))). Every field is a draft for your review."
    }
}

/// Settings → Structure models: Needle's model file, the engine choice, the gate thresholds and voice commands.
@MainActor @Observable public final class StructureSettingsViewModel {
    /// Saved on every change; a run reads the settings when it starts.
    public var settingsValue: StructureSettings {
        didSet { store.save(settingsValue) }
    }
    public private(set) var needleStatus: ModelAssetStatus = .notDownloaded
    public private(set) var lastError: String?
    /// Whether needle-c was linked into this build.
    public let needleInBuild: Bool
    public let notInBuildMessage: String
    public let needleDownloadBytes: Int64?
    public let needleModelSHA256: String?

    @ObservationIgnored private let store: any StructureSettingsStoring
    @ObservationIgnored private let needleAssets: (any ModelAssetManaging)?

    public init(
        store: any StructureSettingsStoring, needleAssets: (any ModelAssetManaging)?, needleInBuild: Bool,
        notInBuildMessage: String, needleDownloadBytes: Int64?, needleModelSHA256: String?
    ) {
        self.store = store
        self.needleAssets = needleAssets
        self.needleInBuild = needleInBuild
        self.notInBuildMessage = notInBuildMessage
        self.needleDownloadBytes = needleDownloadBytes
        self.needleModelSHA256 = needleModelSHA256
        settingsValue = store.load()
    }

    public func refresh() async {
        settingsValue = store.load()
        if let needleAssets { needleStatus = await needleAssets.assetStatus() }
    }

    /// Whether Needle can run now (in the build and downloaded).
    public var isNeedleReady: Bool {
        guard needleInBuild, case .ready = needleStatus else { return false }
        return true
    }

    /// What the engine row says.
    public var engineCaption: String {
        switch settingsValue.engine {
        case .stub: return "STUB: rules, not a model. Confidence is a rule-match strength."
        case .needle:
            if !needleInBuild { return notInBuildMessage + " The STUB runs instead. " + NeedleExperimental.sentence }
            return
                (isNeedleReady
                ? "Needle 3 on this iPhone (CPU). " : "Download Needle 3 below; the STUB runs until then. ")
                + NeedleExperimental.sentence
        }
    }

    /// Settings → Download. Returns true when the model is ready.
    public func downloadNeedle(onProgress: @escaping @MainActor (Double) -> Void) async -> Bool {
        guard let needleAssets, needleInBuild else {
            lastError = notInBuildMessage
            return false
        }
        needleStatus = .downloading(fraction: 0)
        do {
            try await needleAssets.downloadAssets { fraction in
                Task { @MainActor [weak self] in
                    guard let self, case .downloading = self.needleStatus else { return }
                    self.needleStatus = .downloading(fraction: fraction)
                    onProgress(fraction)
                }
            }
        } catch {
            lastError = (error as? any LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        needleStatus = await needleAssets.assetStatus()
        return isNeedleReady
    }

    public func deleteNeedle() async {
        guard let needleAssets else { return }
        do {
            try await needleAssets.deleteAssets()
        } catch {
            lastError = (error as? any LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        needleStatus = await needleAssets.assetStatus()
    }

    public func dismissError() { lastError = nil }

    public func resetThresholds() {
        settingsValue.actThreshold = StructuredResultGate.defaultAct
        settingsValue.provisionalThreshold = StructuredResultGate.defaultProvisional
    }
}
