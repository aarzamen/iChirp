import ChirpCore
import Foundation
import Observation

/// Settings → Speech: model download state for the speech engine and the diarizer, plus the user's preferences.
///
/// The engines are fixed at init. A `parakeetVariant` change is saved here but takes effect only when the app
/// rebuilds its engines (see the ChirpFeatures README).
@MainActor @Observable public final class SpeechSettingsViewModel {
    public private(set) var speechStatus: ModelAssetStatus = .notDownloaded
    public private(set) var diarizerStatus: ModelAssetStatus = .notDownloaded
    /// The last download or delete failure, readable (e.g. the engine's "in use" refusal). Cleared by the next action.
    public private(set) var lastError: String?

    /// The user's preferences. Setting it saves to the settings store.
    public var settingsValue: TranscriptionSettings {
        get { storedSettings }
        set {
            storedSettings = newValue
            settings.save(newValue)
        }
    }

    /// False when the app was built without a diarizer; the diarizer actions then do nothing.
    public var isDiarizerAvailable: Bool { diarizer != nil }

    private var storedSettings: TranscriptionSettings
    @ObservationIgnored private let speech: any SpeechEngine
    @ObservationIgnored private let diarizer: (any SpeakerDiarizing)?
    @ObservationIgnored private let settings: any SettingsStoring
    /// While true, download progress callbacks may update the status; a late hop after the download ends is dropped.
    @ObservationIgnored private var speechDownloadActive = false
    @ObservationIgnored private var diarizerDownloadActive = false

    /// Reads the saved settings and starts a status refresh.
    public init(speech: any SpeechEngine, diarizer: (any SpeakerDiarizing)?, settings: any SettingsStoring) {
        self.speech = speech
        self.diarizer = diarizer
        self.settings = settings
        self.storedSettings = settings.load()
        Task { [weak self] in await self?.refresh() }
    }

    /// Re-reads both model statuses from disk.
    public func refresh() async {
        speechStatus = await speech.assetStatus()
        if let diarizer {
            diarizerStatus = await diarizer.assetStatus()
        }
    }

    /// Clears `lastError` (the alert's dismiss action).
    public func dismissError() {
        lastError = nil
    }

    /// Downloads the speech model. `onProgress` also receives each fraction on the main actor (the app forwards it to
    /// the system's progress UI). Returns whether the model is ready afterwards.
    @discardableResult public func downloadSpeechModel(
        onProgress: (@MainActor (Double) -> Void)? = nil
    ) async -> Bool {
        lastError = nil
        speechDownloadActive = true
        speechStatus = .downloading(fraction: 0)
        do {
            try await speech.downloadAssets { [weak self] fraction in
                Task { @MainActor [weak self] in
                    guard let self, self.speechDownloadActive else { return }
                    self.speechStatus = .downloading(fraction: fraction)
                    onProgress?(fraction)
                }
            }
        } catch {
            record(error)
        }
        speechDownloadActive = false
        speechStatus = await speech.assetStatus()
        if case .ready = speechStatus { return true }
        return false
    }

    public func deleteSpeechModel() async {
        lastError = nil
        do {
            try await speech.deleteAssets()
        } catch {
            record(error)
        }
        speechStatus = await speech.assetStatus()
    }

    /// Downloads the speaker model; `onProgress` as in `downloadSpeechModel`. Returns whether it is ready afterwards
    /// (false, doing nothing, when the app has no diarizer).
    @discardableResult public func downloadDiarizer(
        onProgress: (@MainActor (Double) -> Void)? = nil
    ) async -> Bool {
        guard let diarizer else { return false }
        lastError = nil
        diarizerDownloadActive = true
        diarizerStatus = .downloading(fraction: 0)
        do {
            try await diarizer.downloadAssets { [weak self] fraction in
                Task { @MainActor [weak self] in
                    guard let self, self.diarizerDownloadActive else { return }
                    self.diarizerStatus = .downloading(fraction: fraction)
                    onProgress?(fraction)
                }
            }
        } catch {
            record(error)
        }
        diarizerDownloadActive = false
        diarizerStatus = await diarizer.assetStatus()
        if case .ready = diarizerStatus { return true }
        return false
    }

    public func deleteDiarizer() async {
        guard let diarizer else { return }
        lastError = nil
        do {
            try await diarizer.deleteAssets()
        } catch {
            record(error)
        }
        diarizerStatus = await diarizer.assetStatus()
    }

    private func record(_ error: any Error) {
        if error is CancellationError { return }
        if let description = (error as? any LocalizedError)?.errorDescription, !description.isEmpty {
            lastError = description
        } else {
            lastError = error.localizedDescription
        }
    }
}
