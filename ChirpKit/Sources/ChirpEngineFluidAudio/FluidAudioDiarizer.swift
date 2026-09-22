// Ported from MacParakeet (GPL-3.0): Sources/MacParakeetCore/Services/Diarization/DiarizationService.swift @ bbae9e0e
// L180–L345 and L435–L500: highAccuracyConfig, modelLoader, PLDA repair, S-renumbering, no-speech → empty result.

import ChirpCore
import FluidAudio
import Foundation

/// One FluidAudio diarization segment before renumbering.
struct DiarizedSpan: Sendable, Equatable {
    var speakerId: String
    var startSeconds: Float
    var endSeconds: Float
}

/// FluidAudio's offline diarizer (pyannote Community-1 segmentation, WeSpeaker embeddings, VBx clustering) as a
/// ChirpCore `SpeakerDiarizing` engine, fully on device.
///
/// Like `ParakeetEngine`, nothing is downloaded implicitly: `diarize` throws
/// `SpeechEngineError.modelNotDownloaded` until `downloadAssets` has run.
public actor FluidAudioDiarizer: SpeakerDiarizing {
    public static let engineDescriptor = EngineDescriptor(
        id: "fluidaudio.offline-diarizer",
        kind: .diarization,
        provider: "FluidAudio",
        displayName: "Speaker labels (pyannote Community-1)",
        locality: .onDevice,
        license: "CC-BY-4.0 (model) / Apache-2.0 (FluidAudio)",
        approximateDownloadBytes: 22_000_000,  // measured 21.8 MB on disk (FluidAudio 0.16.1)
        providesWordTimestamps: false,
        supportedLanguages: []
    )

    /// FluidAudio models root; the diarizer lives in `<modelsRoot>/speaker-diarization`.
    public nonisolated let modelsRoot: URL

    private let gate: ANEInferenceGate
    private let downloads = ModelDownloadTracker()
    private var downloadTask: Task<Void, any Error>?
    private var loadTask: Task<Void, any Error>?
    private var models: OfflineDiarizerModels?

    /// - Parameters:
    ///   - modelsRoot: defaults to FluidAudio's own model cache. Tests pass a scratch directory.
    ///   - gate: serializes Neural Engine inference where the OS requires it; share one per process.
    public init(modelsRoot: URL? = nil, gate: ANEInferenceGate = .shared) {
        self.modelsRoot = (modelsRoot ?? FluidAudioModelLocations.defaultModelsRoot).standardizedFileURL
        self.gate = gate
    }

    public nonisolated var descriptor: EngineDescriptor {
        Self.engineDescriptor
    }

    private nonisolated var modelDirectory: URL {
        FluidAudioModelLocations.diarizerDirectory(in: modelsRoot)
    }

    private nonisolated var modelsExist: Bool {
        FluidAudioModelLocations.diarizerModelsExist(in: modelsRoot)
    }

    /// Diarization always runs after transcription, off the interactive path, so it takes FluidAudio's slower
    /// high-accuracy settings rather than `OfflineDiarizerConfig.default` (the fast preset). Upstream measured
    /// 13.89% versus 15.07% DER on VoxConverse for about half the throughput (MacParakeet ADR-010, issue #972).
    ///
    /// Left at library defaults on purpose: `clustering.threshold`, `clustering.constrainedAssignment` and the
    /// fixed K-Means seed.
    static var highAccuracyConfig: OfflineDiarizerConfig {
        var config = OfflineDiarizerConfig.default
        // 10 s windows with a 1 s hop instead of 2 s: more embeddings per speaker turn and finer change points.
        config.segmentation.stepRatio = 0.1
        // Keep short turns: the embedding stage no longer falls back to the overlap-inclusive mask under 1 s, and
        // reconstruction no longer drops segments shorter than 1 s.
        config.embedding.minSegmentDurationSeconds = 0
        // Re-embed spans that received no cluster votes instead of tie-breaking them into cluster 0 (absorbing a
        // speaker's turn into the surrounding speaker).
        config.zeroVoteReembed = OfflineDiarizerConfig.ZeroVoteReembed(enabled: true)
        return config
    }

    // MARK: - ModelAssetManaging

    /// Never downloads; reads the file system and the in-flight download state.
    public func assetStatus() async -> ModelAssetStatus {
        if let fraction = downloads.inFlightFraction {
            return .downloading(fraction: fraction)
        }
        if modelsExist {
            return .ready(bytesOnDisk: FluidAudioModelLocations.byteSize(of: modelDirectory))
        }
        if let failure = downloads.lastFailure {
            return .failed(message: failure)
        }
        return .notDownloaded
    }

    /// Downloads the offline diarizer files (no-op when cached), repairs a malformed PLDA file like upstream's
    /// model loader, and excludes the folder from backups. Compiling happens later, in `prepare`.
    public func downloadAssets(progress: @escaping @Sendable (Double) -> Void) async throws {
        let task: Task<Void, any Error>
        if let downloadTask {
            task = downloadTask
        } else {
            let root = modelsRoot
            let directory = modelDirectory
            let cached = modelsExist
            let tracker = downloads
            tracker.begin()
            let handler = tracker.progressHandler(forwardingTo: progress)
            task = Task {
                defer { self.downloadTask = nil }
                do {
                    if !cached {
                        try await ModelHub.download(.diarizer, to: root, variant: "offline", progressHandler: handler)
                    }
                    try await Self.repairPLDAParameters(modelsRoot: root)
                    try FluidAudioModelLocations.excludeFromBackup(directory)
                    tracker.finish(failure: nil)
                } catch {
                    tracker.finish(failure: SpeechEngineError.failureMessage(for: error))
                    throw error
                }
            }
            downloadTask = task
        }
        progress(0)
        do {
            try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
        } catch {
            throw SpeechEngineError.mapping(error)
        }
        progress(1)
    }

    public func deleteAssets() async throws {
        downloadTask?.cancel()
        models = nil
        do {
            try FluidAudioModelLocations.removeIfPresent(modelDirectory)
        } catch {
            throw SpeechEngineError.mapping(error)
        }
    }

    // MARK: - SpeakerDiarizing

    /// Loads (and CoreML-compiles) the downloaded models. Idempotent; concurrent callers share one load.
    /// Unlike `OfflineDiarizerManager.prepareModels()`, loading does not prewarm with inference, so it never holds
    /// the inference gate.
    public func prepare() async throws {
        if models != nil { return }
        let task: Task<Void, any Error>
        if let loadTask {
            task = loadTask
        } else {
            guard modelsExist else {
                throw SpeechEngineError.modelNotDownloaded(descriptor.displayName)
            }
            let root = modelsRoot
            task = Task {
                defer { self.loadTask = nil }
                let loaded = try await OfflineDiarizerModels.load(from: root)
                self.models = loaded
            }
            loadTask = task
        }
        do {
            try await task.value
        } catch {
            throw SpeechEngineError.mapping(error)
        }
    }

    /// `fileAt` must be 16 kHz mono PCM. Audio without speech yields an empty output rather than an error.
    public func diarize(fileAt url: URL) async throws -> DiarizationOutput {
        do {
            try await prepare()
            guard let models else {
                throw SpeechEngineError.underlying("The speaker diarization model is not loaded.")
            }
            try Task.checkCancellation()
            let config = Self.highAccuracyConfig
            let result: DiarizationResult
            do {
                result = try await gate.withExclusiveAccess {
                    // Each request owns its manager; the loaded models are shared read-only.
                    let manager = OfflineDiarizerManager(config: config)
                    manager.initialize(models: models)
                    return try await manager.process(url)
                }
            } catch let error as OfflineDiarizationError where error.isNoSpeechDetected {
                return DiarizationOutput(segments: [], speakers: [])
            }
            try Task.checkCancellation()
            return Self.output(
                from: result.segments.map {
                    DiarizedSpan(
                        speakerId: $0.speakerId, startSeconds: $0.startTimeSeconds, endSeconds: $0.endTimeSeconds)
                })
        } catch {
            throw SpeechEngineError.mapping(error)
        }
    }

    /// Sorts segments by start time, then renumbers speakers "S1…Sn" in order of first speech, so "S1" is the
    /// first speaker to talk rather than whatever FluidAudio's (undocumented) segment order implies.
    static func output(from spans: [DiarizedSpan]) -> DiarizationOutput {
        let chronological = spans.sorted { $0.startSeconds < $1.startSeconds }

        var idMapping: [String: String] = [:]
        var stableIDs: [String] = []
        for span in chronological where idMapping[span.speakerId] == nil {
            let stableID = "S\(stableIDs.count + 1)"
            idMapping[span.speakerId] = stableID
            stableIDs.append(stableID)
        }

        let segments = chronological.map { span in
            DiarizationSegmentRecord(
                speakerId: idMapping[span.speakerId] ?? span.speakerId,
                startMs: max(0, Int((span.startSeconds * 1000).rounded())),
                endMs: max(0, Int((span.endSeconds * 1000).rounded()))
            )
        }
        let speakers = stableIDs.enumerated().map { index, stableID in
            SpeakerInfo(id: stableID, label: "Speaker \(index + 1)")
        }
        return DiarizationOutput(segments: segments, speakers: speakers)
    }

    // MARK: - PLDA repair

    /// FluidAudio's `ModelHub` repairs compiled models, but the PLDA JSON is parsed outside that recovery, so an
    /// existing malformed file is re-fetched here. Model bundles are never purged, and the old file stays until a
    /// valid replacement arrives. Runs only from `downloadAssets`, the explicit network action.
    static func repairPLDAParameters(
        modelsRoot: URL,
        offlineMode: Bool = ModelHub.offlineMode,
        fetch: @Sendable (URL) async throws -> Data = {
            try await ModelHub.fetchFile(from: $0, description: "speaker PLDA parameters")
        }
    ) async throws {
        try Task.checkCancellation()
        guard !offlineMode else { return }
        let file = FluidAudioModelLocations.diarizerDirectory(in: modelsRoot)
            .appendingPathComponent(ModelNames.OfflineDiarizer.pldaParameters)
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        let existing = try Data(contentsOf: file)
        guard !validPLDAParameters(existing) else { return }
        // FluidAudio 0.16 pins the diarizer to an exact Hugging Face revision; fetch from the same one.
        let url = try ModelRegistry.resolveModel(
            Repo.diarizer.remotePath, ModelNames.OfflineDiarizer.pldaParameters, revision: Repo.diarizer.revision)
        let replacement = try await fetch(url)
        try Task.checkCancellation()
        guard validPLDAParameters(replacement) else {
            throw OfflineDiarizationError.processingFailed("Downloaded PLDA parameters are malformed")
        }
        try replacement.write(to: file, options: .atomic)
    }

    static func validPLDAParameters(_ data: Data) -> Bool {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let tensors = root["tensors"] as? [String: Any],
            let psi = tensors["psi"] as? [String: Any],
            let encoded = psi["data_base64"] as? String,
            let decoded = Data(base64Encoded: encoded, options: [.ignoreUnknownCharacters])
        else { return false }
        return !decoded.isEmpty && decoded.count.isMultiple(of: MemoryLayout<Float>.size)
    }
}

extension OfflineDiarizationError {
    var isNoSpeechDetected: Bool {
        if case .noSpeechDetected = self { return true }
        return false
    }
}
