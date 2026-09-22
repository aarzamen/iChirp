// Ported from MacParakeet (GPL-3.0): Sources/MacParakeetCore/Services/Diarization/DiarizationService.swift @ bbae9e0e
// L180–L345 and L435–L500: highAccuracyConfig, modelLoader, PLDA repair, S-renumbering, no-speech → empty result.
// Models are built from local files (never `OfflineDiarizerModels.load`, which downloads missing files).

import ChirpCore
import CoreML
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
/// `SpeechEngineError.modelNotDownloaded` until `downloadAssets` has run, and `deleteAssets` throws while a
/// diarization runs.
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

    let lifecycle: ModelAssetLifecycle<OfflineDiarizerModels>
    private let gate: ANEInferenceGate

    /// - Parameters:
    ///   - modelsRoot: defaults to FluidAudio's own model cache. Tests pass a scratch directory.
    ///   - gate: serializes Neural Engine inference where the OS requires it; share one per process.
    public init(modelsRoot: URL? = nil, gate: ANEInferenceGate = .shared) {
        let root = (modelsRoot ?? FluidAudioModelLocations.defaultModelsRoot).standardizedFileURL
        self.init(modelsRoot: root, gate: gate, hooks: Self.liveHooks(modelsRoot: root))
    }

    /// Test seam: `hooks` replaces FluidAudio's download, load and file checks.
    init(modelsRoot: URL, gate: ANEInferenceGate, hooks: ModelAssetLifecycle<OfflineDiarizerModels>.Hooks) {
        self.modelsRoot = modelsRoot
        self.gate = gate
        self.lifecycle = ModelAssetLifecycle(hooks: hooks)
    }

    public nonisolated var descriptor: EngineDescriptor {
        Self.engineDescriptor
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

    // MARK: - FluidAudio wiring

    static func liveHooks(modelsRoot: URL) -> ModelAssetLifecycle<OfflineDiarizerModels>.Hooks {
        let directory = FluidAudioModelLocations.diarizerDirectory(in: modelsRoot)
        return ModelAssetLifecycle<OfflineDiarizerModels>.Hooks(
            engineID: engineDescriptor.id,
            displayName: engineDescriptor.displayName,
            modelsPresent: { FluidAudioModelLocations.diarizerModelsExist(in: modelsRoot) },
            bytesOnDisk: { FluidAudioModelLocations.byteSize(of: directory) },
            download: { handler in
                // Download only; CoreML compiles in `prepare`. Skipped when cached, like `AsrModels.download`.
                if !FluidAudioModelLocations.diarizerModelsExist(in: modelsRoot) {
                    try await ModelHub.download(.diarizer, to: modelsRoot, variant: "offline", progressHandler: handler)
                }
                try await repairPLDAParameters(modelsRoot: modelsRoot)
                try FluidAudioModelLocations.excludeFromBackup(directory)
            },
            load: { try await loadLocalModels(directory: directory) },
            remove: { try FluidAudioModelLocations.removeIfPresent(directory) }
        )
    }

    /// Builds `OfflineDiarizerModels` from this exact directory and never downloads. This does what
    /// `OfflineDiarizerModels.load` does without its `ModelHub.loadModels` download and purge-and-re-download
    /// path: Segmentation, Embedding and PldaRho on `.all`, FBank on `.cpuOnly` (fastest on CPU), and the PLDA psi
    /// tensor decoded from `plda-parameters.json`. CoreML compiles synchronously here, off every actor.
    static func loadLocalModels(directory: URL) async throws -> OfflineDiarizerModels {
        let start = Date()
        func model(_ name: String, _ computeUnits: MLComputeUnits) throws -> MLModel {
            let url = directory.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw SpeechEngineError.modelNotDownloaded(engineDescriptor.id)
            }
            let configuration = MLModelConfiguration()
            configuration.computeUnits = computeUnits
            configuration.allowLowPrecisionAccumulationOnGPU = true
            return try MLModel(contentsOf: url, configuration: configuration)
        }
        let names = ModelNames.OfflineDiarizer.self
        let segmentation = try model(names.segmentationPath, .all)
        let embedding = try model(names.embeddingPath, .all)
        let pldaRho = try model(names.pldaRhoPath, .all)
        let fbank = try model(names.fbankPath, .cpuOnly)
        let pldaData = try Data(contentsOf: directory.appendingPathComponent(names.pldaParameters))
        guard let pldaPsi = decodePLDAPsi(pldaData) else {
            throw OfflineDiarizationError.processingFailed("Failed to decode PLDA psi parameters")
        }
        return OfflineDiarizerModels(
            segmentationModel: segmentation,
            fbankModel: fbank,
            embeddingModel: embedding,
            pldaRhoModel: pldaRho,
            pldaPsi: pldaPsi,
            compilationDuration: Date().timeIntervalSince(start)
        )
    }

    // MARK: - ModelAssetManaging

    /// Never downloads; reads the file system and the in-flight download state.
    public func assetStatus() async -> ModelAssetStatus {
        await lifecycle.status()
    }

    /// Downloads the offline diarizer files (no-op when cached), repairs a malformed PLDA file like upstream's
    /// model loader, and excludes the folder from backups. Compiling happens later, in `prepare`.
    public func downloadAssets(progress: @escaping @Sendable (Double) -> Void) async throws {
        try await lifecycle.download(progress: progress)
    }

    /// Throws while a diarization runs. Otherwise cancels and awaits any download or load, then removes the model.
    public func deleteAssets() async throws {
        try await lifecycle.delete()
    }

    // MARK: - SpeakerDiarizing

    /// Loads (and CoreML-compiles) the downloaded models from local files. Idempotent; concurrent callers share one
    /// load. Unlike `OfflineDiarizerManager.prepareModels()`, loading does not prewarm with inference, so it never
    /// holds the inference gate.
    public func prepare() async throws {
        try await lifecycle.prepare()
    }

    /// `fileAt` must be 16 kHz mono PCM. Audio without speech yields an empty output rather than an error.
    public func diarize(fileAt url: URL) async throws -> DiarizationOutput {
        let lease = try await lifecycle.acquire()
        do {
            let output = try await diarize(url, models: lease.runtime)
            await lifecycle.release(lease)
            return output
        } catch {
            await lifecycle.release(lease)
            throw SpeechEngineError.mapping(error)
        }
    }

    private func diarize(_ url: URL, models: OfflineDiarizerModels) async throws -> DiarizationOutput {
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
                DiarizedSpan(speakerId: $0.speakerId, startSeconds: $0.startTimeSeconds, endSeconds: $0.endTimeSeconds)
            })
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

    // MARK: - PLDA parameters

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
        decodePLDAPsi(data) != nil
    }

    /// The `tensors.psi.data_base64` float32 tensor as doubles, decoded the way FluidAudio's
    /// `OfflineDiarizerModels.loadPLDAPsi` does; nil when the file is malformed or the tensor is empty.
    static func decodePLDAPsi(_ data: Data) -> [Double]? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let tensors = root["tensors"] as? [String: Any],
            let psi = tensors["psi"] as? [String: Any],
            let encoded = psi["data_base64"] as? String,
            let decoded = Data(base64Encoded: encoded, options: [.ignoreUnknownCharacters]),
            !decoded.isEmpty, decoded.count.isMultiple(of: MemoryLayout<Float>.size)
        else { return nil }
        var floats = [Float](repeating: 0, count: decoded.count / MemoryLayout<Float>.size)
        _ = floats.withUnsafeMutableBytes { decoded.copyBytes(to: $0) }
        return floats.map(Double.init)
    }
}

extension OfflineDiarizationError {
    var isNoSpeechDetected: Bool {
        if case .noSpeechDetected = self { return true }
        return false
    }
}
