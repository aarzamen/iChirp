// Ported from MacParakeet (GPL-3.0): Sources/MacParakeetCore/Services/MeetingRecording/MeetingVADService.swift @ bbae9e0e
// Changes: the FluidAudio side of `MeetingVADService` (Silero `VadManager` on `.cpuOnly`, `makeIfModelCached`,
// `downloadModel`, `processStreamingChunk` with `fluidConfig`) behind `ChirpCore.VoiceActivityDetecting`, plus
// `ModelAssetManaging` so the download is an explicit, visible action. The stream state lives in a per-recording
// `VoiceActivityStream` actor. Review R3-3: the model runs through the shared `ModelAssetLifecycle` like the diarizer
// (strict completeness, backup exclusion, one shared load from local files only, never a download from `makeStream`).

@preconcurrency import CoreML
import ChirpCore
import FluidAudio
import Foundation

/// Silero voice-activity detection (M3 live meeting chunks). Runs on the **CPU only**, so the Neural Engine stays
/// free for Parakeet's live chunks and final pass (plan 012 maintenance note). The model (about 2 MB) is fetched only
/// by `downloadAssets` (Settings → Meetings), never by `makeStream`.
///
/// Lifecycle (review R3-3): the same `ModelAssetLifecycle` as Parakeet and the diarizer. Ready means complete (the
/// bundle with its `coremldata.bin`, no `*.partial` file, from the pinned revision); the download excludes the folder
/// from backups; `makeStream` loads once from local files (`VadManager(config:vadModel:)`), shared by concurrent
/// callers, and a model that is missing, downloading, being deleted or cannot load gives no stream (fixed chunks)
/// instead of FluidAudio purging the folder and downloading it again.
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
    let lifecycle: ModelAssetLifecycle<VadManager>
    private let logger = Log.logger("vad")

    public init(modelsRoot: URL? = nil) {
        let root = (modelsRoot ?? FluidAudioModelLocations.defaultModelsRoot).standardizedFileURL
        self.init(modelsRoot: root, hooks: Self.liveHooks(modelsRoot: root), network: .live)
    }

    /// Test seam: `hooks` replaces FluidAudio's download, load and file checks; `network` the path check and the
    /// retry backoff.
    init(modelsRoot: URL, hooks: ModelAssetLifecycle<VadManager>.Hooks, network: DownloadNetworkPolicy) {
        self.modelsRoot = modelsRoot
        lifecycle = ModelAssetLifecycle(hooks: hooks, network: network)
    }

    nonisolated var modelDirectory: URL {
        FluidAudioModelLocations.voiceActivityDirectory(in: modelsRoot)
    }

    // MARK: - FluidAudio wiring

    static func liveHooks(modelsRoot: URL) -> ModelAssetLifecycle<VadManager>.Hooks {
        let directory = FluidAudioModelLocations.voiceActivityDirectory(in: modelsRoot)
        return ModelAssetLifecycle<VadManager>.Hooks(
            engineID: engineID,
            displayName: "Silero voice activity",
            modelsPresent: { FluidAudioModelLocations.voiceActivityModelsExist(in: modelsRoot) },
            bytesOnDisk: { FluidAudioModelLocations.byteSize(of: directory) },
            download: { handler in
                // Download only (CoreML compiles at the first `makeStream`). `ModelHub.download` resumes `.partial`
                // files and deletes nothing; it is skipped when the cache is already complete.
                if !FluidAudioModelLocations.voiceActivityModelsExist(in: modelsRoot) {
                    try await ModelHub.download(.vad, to: modelsRoot, progressHandler: handler)
                }
                try FluidAudioModelLocations.excludeFromBackup(directory)
            },
            load: { try await loadLocalModel(directory: directory) },
            remove: { try FluidAudioModelLocations.removeIfPresent(directory) }
        )
    }

    /// Builds the Silero `VadManager` from this exact directory, on the CPU, and never downloads: this is what
    /// `VadManager(config:modelDirectory:)` does without its `ModelHub.loadModels`, which downloads missing files and
    /// purges and re-downloads after a failed load. A folder downloaded before review R3-3 was never excluded from
    /// backups; that is done here too (best effort, local only). `@concurrent`: CoreML compiles synchronously.
    @concurrent
    static func loadLocalModel(directory: URL) async throws -> VadManager {
        let url = directory.appendingPathComponent(ModelNames.VAD.sileroVadFile)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw SpeechEngineError.modelNotDownloaded(engineID)
        }
        try? FluidAudioModelLocations.excludeFromBackup(directory)
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuOnly
        configuration.allowLowPrecisionAccumulationOnGPU = true
        let model = try MLModel(contentsOf: url, configuration: configuration)
        return VadManager(config: VadConfig(computeUnits: .cpuOnly), vadModel: model)
    }

    // MARK: - ModelAssetManaging

    /// Never downloads; reads the file system and the in-flight download state.
    public func assetStatus() async -> ModelAssetStatus {
        await lifecycle.status()
    }

    /// Fetches the Silero model from Hugging Face (network; the person tapped Download), then excludes its folder from
    /// backups. Retries transient failures; cancellation stops it.
    public func downloadAssets(progress: @escaping @Sendable (Double) -> Void) async throws {
        try await lifecycle.download(progress: progress)
    }

    /// Cancels and awaits a download or load in flight, then removes the model. A meeting already recording keeps
    /// its stream (the model stays in its memory) until it stops.
    public func deleteAssets() async throws {
        try await lifecycle.delete()
    }

    // MARK: - VoiceActivityDetecting

    /// A stream over a model already on disk, or nil (never downloads: an unready model means fixed chunks).
    public func makeStream(config: VoiceActivityConfig) async -> (any VoiceActivityStream)? {
        let manager: VadManager
        do {
            // The lease only guards the load; a stream lives for a whole meeting and needs no lease.
            let lease = try await lifecycle.acquire()
            manager = lease.runtime
            await lifecycle.release(lease)
        } catch {
            if case .modelNotDownloaded? = error as? SpeechEngineError { return nil }
            logger.error("vad_load_failed error_type=\(String(describing: type(of: error)), privacy: .public)")
            return nil
        }
        guard await manager.isAvailable else { return nil }
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
