import ChirpCore
import Foundation
import Observation

/// Settings → Meetings (M3): how long meeting audio is kept, and the optional voice-activity model that lets live
/// text cut at pauses.
@MainActor @Observable public final class MeetingSettingsViewModel {
    public private(set) var voiceActivityStatus: ModelAssetStatus = .notDownloaded
    /// The last download or delete failure, readable. Cleared by the next action.
    public private(set) var lastError: String?

    /// Saved onto the **freshest** stored settings, so fields other screens own are never overwritten.
    public var retention: MeetingAudioRetention {
        get { storedRetention }
        set {
            var merged = settings.load()
            merged.meetingAudioRetentionDays = newValue.days
            settings.save(merged)
            storedRetention = newValue
        }
    }

    public var isVoiceActivityAvailable: Bool { voiceActivity != nil }
    /// The model's download size, for "about 2 MB".
    public var voiceActivityDownloadBytes: Int64? { voiceActivity?.descriptor.approximateDownloadBytes }

    private var storedRetention: MeetingAudioRetention
    @ObservationIgnored private let voiceActivity: (any VoiceActivityDetecting)?
    @ObservationIgnored private let settings: any SettingsStoring

    public init(voiceActivity: (any VoiceActivityDetecting)?, settings: any SettingsStoring) {
        self.voiceActivity = voiceActivity
        self.settings = settings
        self.storedRetention = MeetingAudioRetention(days: settings.load().meetingAudioRetentionDays)
    }

    public func refresh() async {
        storedRetention = MeetingAudioRetention(days: settings.load().meetingAudioRetentionDays)
        if let voiceActivity {
            voiceActivityStatus = await voiceActivity.assetStatus()
        }
    }

    /// Downloads the voice-activity model (the person tapped Download). Returns whether it is ready afterwards.
    @discardableResult
    public func downloadVoiceActivityModel(onProgress: @escaping @MainActor (Double) -> Void = { _ in }) async -> Bool {
        guard let voiceActivity else { return false }
        lastError = nil
        voiceActivityStatus = .downloading(fraction: 0)
        do {
            try await voiceActivity.downloadAssets { fraction in
                Task { @MainActor [weak self] in
                    guard let self, case .downloading = self.voiceActivityStatus else { return }
                    self.voiceActivityStatus = .downloading(fraction: fraction)
                    onProgress(fraction)
                }
            }
        } catch {
            lastError = (error as? any LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        voiceActivityStatus = await voiceActivity.assetStatus()
        if case .ready = voiceActivityStatus { return true }
        return false
    }

    public func deleteVoiceActivityModel() async {
        guard let voiceActivity else { return }
        lastError = nil
        do {
            try await voiceActivity.deleteAssets()
        } catch {
            lastError = (error as? any LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        voiceActivityStatus = await voiceActivity.assetStatus()
    }

    public func dismissError() { lastError = nil }
}
