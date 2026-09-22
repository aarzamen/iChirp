// Ported from MacParakeet (GPL-3.0): Sources/MacParakeetCore/Services/MeetingRecording/MeetingVADService.swift @ bbae9e0e
// Changes: the FluidAudio side of `MeetingVADService` (Silero `VadManager` on `.cpuOnly`, `makeIfModelCached`,
// `downloadModel`, `processStreamingChunk` with `fluidConfig`) behind `ChirpCore.VoiceActivityDetecting`, plus
// `ModelAssetManaging` so the download is an explicit, visible action. The stream state lives in a per-recording
// `VoiceActivityStream` actor.

@preconcurrency import CoreML
import ChirpCore
import FluidAudio
import Foundation

/// Silero voice-activity detection (M3 live meeting chunks). Runs on the **CPU only**, so the Neural Engine stays
/// free for Parakeet's live chunks and final pass (plan 012 maintenance note). The model (about 2 MB) is fetched only
/// by `downloadAssets` (Settings → Meetings), never by `makeStream`.
public actor FluidAudioVoiceActivity: VoiceActivityDetecting {
    public static let engineID = "fluidaudio.silero-vad"

    public nonisolated let descriptor = EngineDescriptor(
        id: FluidAudioVoiceActivity.engineID,
        kind: .voiceActivity,
        provider: "FluidAudio",
        displayName: "Silero voice activity",
        locality: .onDevice,
        license: "MIT",
        approximateDownloadBytes: 2_000_000
    )
    public nonisolated let windowSize = VadManager.chunkSize

    /// FluidAudio's `Models` folder (the same root Parakeet and the diarizer use).
    public nonisolated let modelsRoot: URL
    private var manager: VadManager?
    private var downloadFraction: Double?
    private let logger = Log.logger("vad")

    public init(modelsRoot: URL? = nil) {
        self.modelsRoot = (modelsRoot ?? FluidAudioModelLocations.defaultModelsRoot).standardizedFileURL
    }

    nonisolated var modelDirectory: URL {
        modelsRoot.appendingPathComponent(Repo.vad.folderName, isDirectory: true)
    }

    nonisolated var isModelCached: Bool {
        ModelNames.VAD.requiredModels.allSatisfy {
            FileManager.default.fileExists(atPath: modelDirectory.appendingPathComponent($0).path)
        }
    }

    public func assetStatus() async -> ModelAssetStatus {
        if let downloadFraction { return .downloading(fraction: downloadFraction) }
        guard isModelCached else { return .notDownloaded }
        return .ready(bytesOnDisk: FluidAudioModelLocations.byteSize(of: modelDirectory))
    }

    /// Fetches the Silero model from Hugging Face (network; the person tapped Download).
    public func downloadAssets(progress: @escaping @Sendable (Double) -> Void) async throws {
        downloadFraction = 0
        defer { downloadFraction = nil }
        do {
            manager = try await VadManager(
                config: VadConfig(computeUnits: .cpuOnly), modelDirectory: modelsRoot.deletingLastPathComponent(),
                progressHandler: { value in progress(min(max(value.fractionCompleted, 0), 1)) })
            progress(1)
        } catch {
            throw SpeechEngineError.mapping(error)
        }
    }

    public func deleteAssets() async throws {
        manager = nil
        guard FileManager.default.fileExists(atPath: modelDirectory.path) else { return }
        try FileManager.default.removeItem(at: modelDirectory)
    }

    /// A stream over a model already on disk, or nil (never downloads: an uncached model means fixed chunks).
    public func makeStream(config: VoiceActivityConfig) async -> (any VoiceActivityStream)? {
        guard isModelCached, downloadFraction == nil else { return nil }
        if manager == nil {
            do {
                manager = try await VadManager(
                    config: VadConfig(computeUnits: .cpuOnly), modelDirectory: modelsRoot.deletingLastPathComponent())
            } catch {
                logger.error("vad_load_failed error_type=\(String(describing: type(of: error)), privacy: .public)")
                return nil
            }
        }
        guard let manager, await manager.isAvailable else { return nil }
        let segmentation = VadSegmentationConfig(
            minSilenceDuration: config.minSilenceSeconds, speechPadding: config.speechPaddingSeconds)
        return FluidAudioVoiceActivityStream(
            manager: manager, state: await manager.makeStreamState(), config: segmentation)
    }
}

/// One recording's Silero stream state.
actor FluidAudioVoiceActivityStream: VoiceActivityStream {
    private let manager: VadManager
    private var state: VadStreamState
    private let config: VadSegmentationConfig

    init(manager: VadManager, state: VadStreamState, config: VadSegmentationConfig) {
        self.manager = manager
        self.state = state
        self.config = config
    }

    func process(_ window: [Float]) async throws -> VoiceActivityEvent? {
        let result = try await manager.processStreamingChunk(window, state: state, config: config)
        state = result.state
        guard let event = result.event else { return nil }
        switch event.kind {
        case .speechStart: return .speechStart
        case .speechEnd: return .speechEnd(sampleIndex: event.sampleIndex)
        }
    }
}
