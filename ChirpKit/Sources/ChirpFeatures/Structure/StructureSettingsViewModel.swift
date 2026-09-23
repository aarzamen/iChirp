import ChirpCore
import Foundation
import Observation

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
            if !needleInBuild { return notInBuildMessage + " The STUB runs instead." }
            return isNeedleReady
                ? "Needle 3 on this iPhone (CPU)." : "Download Needle 3 below; the STUB runs until then."
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
