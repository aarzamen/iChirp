// Ported from MacParakeet (GPL-3.0): Sources/MacParakeetCore/STT/STTRuntime.swift @ bbae9e0e
// Parakeet TDT download (~L1875), load (~L2330) and file transcription (~L700–L760) as one ChirpCore engine.

import AVFoundation
import ChirpCore
import FluidAudio
import Foundation

/// Parakeet TDT 0.6B speech recognition on FluidAudio (CoreML, Neural Engine), fully on device.
///
/// Lifecycle: `downloadAssets` fetches the model into `modelsRoot`, `prepare` loads it into memory, and
/// `transcribe` runs it. Nothing is ever downloaded implicitly: with missing models `prepare` and `transcribe`
/// throw `SpeechEngineError.modelNotDownloaded`.
public actor ParakeetEngine: SpeechEngine {
    public static let engineID = "fluidaudio.parakeet-tdt"

    /// Parakeet TDT v3's 25 European languages (BCP-47), per the model card.
    static let v3Languages = [
        "bg", "cs", "da", "de", "el", "en", "es", "et", "fi", "fr", "hr", "hu", "it",
        "lt", "lv", "mt", "nl", "pl", "pt", "ro", "ru", "sk", "sl", "sv", "uk",
    ]

    public nonisolated let variant: ParakeetVariant
    /// FluidAudio models root; the model lives in `<modelsRoot>/<repo folder>`.
    public nonisolated let modelsRoot: URL

    private let gate: ANEInferenceGate
    private let downloads = ModelDownloadTracker()
    private var downloadTask: Task<Void, any Error>?
    private var loadTask: Task<Void, any Error>?
    private var manager: AsrManager?
    private var decoderLayerCount: Int?

    /// - Parameters:
    ///   - modelsRoot: defaults to FluidAudio's own model cache. Tests pass a scratch directory.
    ///   - gate: serializes Neural Engine inference where the OS requires it; share one per process.
    public init(variant: ParakeetVariant = .v3, modelsRoot: URL? = nil, gate: ANEInferenceGate = .shared) {
        self.variant = variant
        self.modelsRoot = (modelsRoot ?? FluidAudioModelLocations.defaultModelsRoot).standardizedFileURL
        self.gate = gate
    }

    public nonisolated var descriptor: EngineDescriptor {
        Self.descriptor(for: variant)
    }

    public static func descriptor(for variant: ParakeetVariant) -> EngineDescriptor {
        EngineDescriptor(
            id: engineID,
            kind: .speech,
            provider: "FluidAudio",
            displayName: variant == .v3 ? "Parakeet TDT 0.6B v3" : "Parakeet TDT 0.6B v2 (English)",
            locality: .onDevice,
            license: "CC-BY-4.0 (model) / Apache-2.0 (FluidAudio)",
            approximateDownloadBytes: 500_000_000,
            providesWordTimestamps: true,
            supportedLanguages: variant == .v3 ? v3Languages : ["en"]
        )
    }

    private nonisolated var modelDirectory: URL {
        FluidAudioModelLocations.parakeetDirectory(in: modelsRoot, variant: variant)
    }

    private nonisolated var asrVersion: AsrModelVersion {
        FluidAudioModelLocations.asrVersion(for: variant)
    }

    private nonisolated var modelsExist: Bool {
        FluidAudioModelLocations.parakeetModelsExist(in: modelsRoot, variant: variant)
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

    /// Downloads (or validates) the model via `AsrModels.download`, then excludes its folder from backups.
    /// A second call while one is running joins it and sees only 0 and 1 as progress.
    public func downloadAssets(progress: @escaping @Sendable (Double) -> Void) async throws {
        let task: Task<Void, any Error>
        if let downloadTask {
            task = downloadTask
        } else {
            let directory = modelDirectory
            let version = asrVersion
            let tracker = downloads
            tracker.begin()
            let handler = tracker.progressHandler(forwardingTo: progress)
            task = Task {
                defer { self.downloadTask = nil }
                do {
                    _ = try await AsrModels.download(to: directory, version: version, progressHandler: handler)
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
        await manager?.cleanup()
        manager = nil
        decoderLayerCount = nil
        do {
            try FluidAudioModelLocations.removeIfPresent(modelDirectory)
        } catch {
            throw SpeechEngineError.mapping(error)
        }
    }

    // MARK: - SpeechEngine

    /// Loads the downloaded model into an `AsrManager`. Idempotent; concurrent callers share one load.
    public func prepare() async throws {
        if manager != nil { return }
        let task: Task<Void, any Error>
        if let loadTask {
            task = loadTask
        } else {
            guard modelsExist else {
                throw SpeechEngineError.modelNotDownloaded(descriptor.displayName)
            }
            task = Task {
                defer { self.loadTask = nil }
                try await self.loadModels()
            }
            loadTask = task
        }
        do {
            try await task.value
        } catch {
            throw SpeechEngineError.mapping(error)
        }
    }

    private func loadModels() async throws {
        let models = try await AsrModels.load(
            from: modelDirectory,
            version: asrVersion,
            encoderComputeUnits: ParakeetASRConfig.encoderComputeUnits()
        )
        let loadedManager = AsrManager(config: ParakeetASRConfig.make())
        try await loadedManager.loadModels(models)
        decoderLayerCount = await loadedManager.decoderLayerCount
        manager = loadedManager
    }

    /// `fileAt` must be 16 kHz mono PCM. Progress reports 0 at the start and 1 at the end, with FluidAudio's
    /// per-chunk progress in between for files longer than one 15 s window.
    public func transcribe(
        fileAt url: URL,
        options: SpeechTranscriptionOptions,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> SpeechResult {
        do {
            try await prepare()
            guard let manager, let decoderLayers = decoderLayerCount else {
                throw SpeechEngineError.underlying("The Parakeet model is not loaded.")
            }
            progress(0)
            let progressTask = await Self.forwardChunkProgress(of: manager, for: url, to: progress)
            defer { progressTask?.cancel() }

            try Task.checkCancellation()
            var decoderState = TdtDecoderState.make(decoderLayers: decoderLayers)
            let language = Self.fluidAudioLanguage(forHint: options.languageHint, variant: variant)
            try Task.checkCancellation()
            // Gate only the CoreML inference call; model loading and progress plumbing stay outside it.
            let result = try await gate.withExclusiveAccess {
                try await manager.transcribe(url, decoderState: &decoderState, language: language)
            }
            try Task.checkCancellation()

            guard !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw SpeechEngineError.emptyTranscript
            }
            let words = WordTimingBuilder.words(from: result.tokenTimings)
            progress(1)
            return SpeechResult(
                text: result.text,
                words: words,
                // v2 is English-only. FluidAudio's `ASRResult` does not report a detected language for v3.
                language: variant == .v2 ? "en" : nil,
                engineID: Self.engineID,
                engineVariant: variant.rawValue
            )
        } catch {
            throw SpeechEngineError.mapping(error)
        }
    }

    /// FluidAudio only emits chunk progress for audio longer than one model window, and only finishes the
    /// session it opened for such audio, so the stream is opened (before inference starts) only in that case.
    private static func forwardChunkProgress(
        of manager: AsrManager,
        for url: URL,
        to progress: @escaping @Sendable (Double) -> Void
    ) async -> Task<Void, Never>? {
        guard let samples = estimatedSampleCount(of: url), samples > ASRConstants.maxModelSamples else {
            return nil
        }
        let stream = await manager.transcriptionProgressStream
        return Task {
            do {
                for try await value in stream {
                    progress(min(0.99, max(0, value)))
                }
            } catch {
                // The transcription itself reports its failure.
            }
        }
    }

    /// Length in 16 kHz samples, or nil when the file cannot be opened (transcription will report why).
    private static func estimatedSampleCount(of url: URL) -> Int? {
        guard let file = try? AVAudioFile(forReading: url), file.fileFormat.sampleRate > 0 else {
            return nil
        }
        let ratio = Double(ASRConstants.sampleRate) / file.fileFormat.sampleRate
        return Int((Double(file.length) * ratio).rounded(.up))
    }

    /// Parakeet v3 accepts a language for script-aware token filtering; v2 is English-only and ignores it.
    static func fluidAudioLanguage(forHint hint: String?, variant: ParakeetVariant) -> Language? {
        guard variant == .v3, let hint else { return nil }
        guard let primary = hint.split(whereSeparator: { $0 == "-" || $0 == "_" }).first else { return nil }
        return Language(rawValue: primary.lowercased())
    }
}
