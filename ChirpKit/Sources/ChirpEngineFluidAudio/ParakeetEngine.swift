// Ported from MacParakeet (GPL-3.0): Sources/MacParakeetCore/STT/STTRuntime.swift @ bbae9e0e
// Parakeet TDT download (~L1875), load (~L2330: one AsrManager per concurrent job over shared read-only models) and
// file transcription (~L700–L760) as one ChirpCore engine; models load from local files only. M2 adds the dictation
// trailing-silence pad (~L660–L830, `paddedDictationSamples`) and the tail-window preview's in-memory pass
// (`transcribeParakeetPreview`, ~L1223).

import AVFoundation
import ChirpCore
import FluidAudio
import Foundation

/// What one transcription needs from FluidAudio. `AsrManager` conforms as is; tests substitute fakes.
protocol ParakeetWorker: Actor {
    var transcriptionProgressStream: AsyncThrowingStream<Double, any Error> { get async }
    func transcribe(_ url: URL, decoderState: inout TdtDecoderState, language: Language?) async throws -> ASRResult
    /// 16 kHz mono samples held in memory (the live preview window, a padded short dictation).
    func transcribe(_ samples: [Float], decoderState: inout TdtDecoderState, language: Language?) async throws
        -> ASRResult
    func cleanup()
}

extension AsrManager: ParakeetWorker {}

/// A loaded Parakeet model: every worker made by `makeWorker` shares one read-only `AsrModels`.
struct ParakeetRuntime: Sendable {
    let decoderLayerCount: Int
    let makeWorker: @Sendable () -> any ParakeetWorker
}

/// Parakeet TDT 0.6B speech recognition on FluidAudio (CoreML, Neural Engine), fully on device.
///
/// Lifecycle: `downloadAssets` fetches the model into `modelsRoot`, `prepare` loads it into memory, and
/// `transcribe` runs it. Nothing is ever downloaded implicitly: with missing models (or while a download or delete
/// runs) `prepare` and `transcribe` throw `SpeechEngineError.modelNotDownloaded`.
///
/// Concurrency: each `transcribe` call checks out its own `AsrManager` from a small idle pool, because an
/// `AsrManager` has exactly one progress stream and one progress session. Two jobs on one manager would share (and
/// crash on) that stream. `deleteAssets` throws while a transcription runs.
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

    let lifecycle: ModelAssetLifecycle<ParakeetRuntime>
    private let gate: ANEInferenceGate
    private var idleWorkers: [any ParakeetWorker] = []
    private var idleWorkersGeneration = 0

    /// - Parameters:
    ///   - modelsRoot: defaults to FluidAudio's own model cache. Tests pass a scratch directory.
    ///   - gate: serializes Neural Engine inference where the OS requires it; share one per process.
    public init(variant: ParakeetVariant = .v3, modelsRoot: URL? = nil, gate: ANEInferenceGate = .shared) {
        let root = (modelsRoot ?? FluidAudioModelLocations.defaultModelsRoot).standardizedFileURL
        self.init(
            variant: variant, modelsRoot: root, gate: gate, hooks: Self.liveHooks(variant: variant, modelsRoot: root),
            network: .live)
    }

    /// Test seam: `hooks` replaces FluidAudio's download, load and file checks; `network` the path check and the
    /// retry backoff.
    init(
        variant: ParakeetVariant, modelsRoot: URL, gate: ANEInferenceGate,
        hooks: ModelAssetLifecycle<ParakeetRuntime>.Hooks, network: DownloadNetworkPolicy
    ) {
        self.variant = variant
        self.modelsRoot = modelsRoot
        self.gate = gate
        self.lifecycle = ModelAssetLifecycle(hooks: hooks, network: network)
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

    // MARK: - FluidAudio wiring

    static func liveHooks(variant: ParakeetVariant, modelsRoot: URL) -> ModelAssetLifecycle<ParakeetRuntime>.Hooks {
        let directory = FluidAudioModelLocations.parakeetDirectory(in: modelsRoot, variant: variant)
        let version = FluidAudioModelLocations.asrVersion(for: variant)
        let repo = FluidAudioModelLocations.asrRepo(for: variant)
        let downloadVariant = FluidAudioModelLocations.downloadVariant(for: variant)
        return ModelAssetLifecycle<ParakeetRuntime>.Hooks(
            engineID: engineID,
            displayName: descriptor(for: variant).displayName,
            modelsPresent: { FluidAudioModelLocations.parakeetModelsExist(in: modelsRoot, variant: variant) },
            bytesOnDisk: { FluidAudioModelLocations.byteSize(of: directory) },
            download: { handler in
                if FluidAudioModelLocations.parakeetNeedsRepair(in: modelsRoot, variant: variant) {
                    // A partial cache that `AsrModels.download` would skip: fetch the missing files and resume the
                    // `.partial` ones (nothing is deleted), then let it finish as usual.
                    try await ModelHub.download(
                        repo, to: modelsRoot, variant: downloadVariant, progressHandler: handler)
                }
                _ = try await AsrModels.download(to: directory, version: version, progressHandler: handler)
                try FluidAudioModelLocations.excludeFromBackup(directory)
            },
            load: { try await loadRuntime(directory: directory, version: version) },
            remove: { try FluidAudioModelLocations.removeIfPresent(directory) }
        )
    }

    /// Loads from this exact directory and never downloads. `AsrModels.load` is not used because its
    /// `ModelHub.loadModels` fetches missing files and purges and re-downloads after a failed load. `loadLocal`
    /// compiles synchronously, so it runs here on the generic executor, off every actor (`@concurrent`, so that
    /// holds under any default for nonisolated async functions).
    @concurrent
    static func loadRuntime(directory: URL, version: AsrModelVersion) async throws -> ParakeetRuntime {
        let models = try AsrModels.loadLocal(
            from: directory, version: version, encoderComputeUnits: ParakeetASRConfig.encoderComputeUnits())
        let config = ParakeetASRConfig.make()
        return ParakeetRuntime(
            decoderLayerCount: models.version.decoderLayers,
            makeWorker: { AsrManager(config: config, models: models) }
        )
    }

    // MARK: - ModelAssetManaging

    /// Never downloads; reads the file system and the in-flight download state.
    public func assetStatus() async -> ModelAssetStatus {
        await lifecycle.status()
    }

    /// Downloads (or validates) the model via `AsrModels.download`, first repairing a partial cache it would skip,
    /// then excludes its folder from backups.
    /// A second call while one is running joins it and sees only 0 and 1 as progress.
    public func downloadAssets(progress: @escaping @Sendable (Double) -> Void) async throws {
        try await lifecycle.download(progress: progress)
    }

    /// Throws while a transcription runs. Otherwise cancels and awaits any download or load, then removes the model.
    public func deleteAssets() async throws {
        try await lifecycle.delete()
        let workers = idleWorkers
        idleWorkers = []
        for worker in workers {
            await worker.cleanup()
        }
    }

    // MARK: - SpeechEngine

    /// Loads the downloaded model from local files. Idempotent; concurrent callers share one load.
    public func prepare() async throws {
        try await lifecycle.prepare()
    }

    /// `fileAt` must be 16 kHz mono PCM. Progress reports 0 at the start and 1 at the end, with FluidAudio's
    /// per-chunk progress in between for files longer than one 15 s window.
    public func transcribe(
        fileAt url: URL,
        options: SpeechTranscriptionOptions,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> SpeechResult {
        // A short dictation is decoded into memory and padded with 0.5 s of silence (upstream issue #562), so the
        // decoder emits a last word that lands right on the end of the recording. Long clips keep the URL path.
        let input: ParakeetInput
        if options.purpose == .dictation, let padded = await Self.paddedDictationSamples(of: url) {
            input = .samples(padded)
        } else {
            input = .file(url)
        }
        let lease = try await lifecycle.acquire()
        let worker = checkOutWorker(for: lease)
        do {
            let result = try await transcribe(
                input, with: worker, decoderLayers: lease.runtime.decoderLayerCount, options: options,
                progress: progress)
            checkIn(worker, for: lease)
            await lifecycle.release(lease)
            return result
        } catch {
            // The worker is dropped, not checked in: a manager that threw (or was cancelled) part-way through may
            // hold half-finished decoder or progress-stream state. The next job makes a fresh one on the same
            // models. No `cleanup()`: it also clears FluidAudio's process-wide MLArray cache other jobs use.
            await lifecycle.release(lease)
            throw SpeechEngineError.mapping(error)
        }
    }

    /// What one inference reads: a file (disk-backed chunking for long audio) or samples already in memory.
    enum ParakeetInput: Sendable {
        case file(URL)
        case samples([Float])
    }

    private func transcribe(
        _ input: ParakeetInput,
        with worker: any ParakeetWorker,
        decoderLayers: Int,
        options: SpeechTranscriptionOptions,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> SpeechResult {
        progress(0)
        var progressTask: Task<Void, Never>?
        if case .file(let url) = input {
            progressTask = await Self.forwardChunkProgress(of: worker, for: url, to: progress)
        }
        defer { progressTask?.cancel() }

        try Task.checkCancellation()
        var decoderState = TdtDecoderState.make(decoderLayers: decoderLayers)
        let language = Self.fluidAudioLanguage(forHint: options.languageHint, variant: variant)
        // Gate only the CoreML inference call; model loading and progress plumbing stay outside it.
        let result = try await gate.withExclusiveAccess {
            switch input {
            case .file(let url):
                try await worker.transcribe(url, decoderState: &decoderState, language: language)
            case .samples(let samples):
                try await worker.transcribe(samples, decoderState: &decoderState, language: language)
            }
        }
        try Task.checkCancellation()

        guard !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SpeechEngineError.emptyTranscript
        }
        let words = WordTimingBuilder.words(from: result.tokenTimings)
        // Drain the forwarder first so no chunk value can arrive after the final 1.
        progressTask?.cancel()
        await progressTask?.value
        progress(1)
        return SpeechResult(
            text: result.text,
            words: words,
            // v2 is English-only. FluidAudio's `ASRResult` does not report a detected language for v3.
            language: variant == .v2 ? "en" : nil,
            engineID: Self.engineID,
            engineVariant: variant.rawValue
        )
    }

    // MARK: - Live preview (M2)

    /// One preview pass: the window's text, or "" when nothing was recognized. Same lease and worker pool as a file
    /// job; no progress, no word timings. Display-only (spec/contracts/speech-engine-plugin-v1.md).
    func transcribePreview(_ window: [Float], options: SpeechTranscriptionOptions) async throws -> String {
        let lease = try await lifecycle.acquire()
        let worker = checkOutWorker(for: lease)
        do {
            try Task.checkCancellation()
            var decoderState = TdtDecoderState.make(decoderLayers: lease.runtime.decoderLayerCount)
            let language = Self.fluidAudioLanguage(forHint: options.languageHint, variant: variant)
            let result = try await gate.withExclusiveAccess {
                try await worker.transcribe(window, decoderState: &decoderState, language: language)
            }
            checkIn(worker, for: lease)
            await lifecycle.release(lease)
            return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            await lifecycle.release(lease)
            throw SpeechEngineError.mapping(error)
        }
    }

    // MARK: - Dictation pad (M2)

    /// Trailing silence appended to a short dictation before its final pass (upstream
    /// `STTRuntime.dictationTrailingSilenceSeconds`).
    static let dictationTrailingSilenceSeconds = 0.5

    /// The recording's samples plus 0.5 s of silence when the **padded** clip still fits one model window; nil
    /// (keep the disk-backed URL path) for a long, empty or unreadable file, or one not at 16 kHz mono. The length
    /// is checked before reading, so a long file is never loaded into memory. `@concurrent`: file reading stays off
    /// the engine actor.
    @concurrent
    static func paddedDictationSamples(of url: URL) async -> [Float]? {
        let padCount = Int(dictationTrailingSilenceSeconds * Double(ASRConstants.sampleRate))
        guard let file = try? AVAudioFile(forReading: url),
            file.processingFormat.sampleRate == Double(ASRConstants.sampleRate),
            file.processingFormat.channelCount == 1,
            file.length > 0, file.length + Int64(padCount) <= Int64(ASRConstants.maxModelSamples),
            let buffer = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
            (try? file.read(into: buffer)) != nil,
            let data = buffer.floatChannelData?[0], buffer.frameLength > 0
        else { return nil }
        var samples = Array(UnsafeBufferPointer(start: data, count: Int(buffer.frameLength)))
        samples.append(contentsOf: repeatElement(0, count: padCount))
        return samples
    }

    // MARK: - Worker pool

    /// An idle worker for the lease's generation, or a new one. A worker serves one transcription at a time.
    private func checkOutWorker(for lease: ModelLease<ParakeetRuntime>) -> any ParakeetWorker {
        if lease.generation != idleWorkersGeneration {
            idleWorkers.removeAll()
            idleWorkersGeneration = lease.generation
        }
        return idleWorkers.popLast() ?? lease.runtime.makeWorker()
    }

    /// Returns a worker that finished cleanly to the pool, unless its model generation has been deleted since.
    private func checkIn(_ worker: any ParakeetWorker, for lease: ModelLease<ParakeetRuntime>) {
        guard lease.generation == idleWorkersGeneration else { return }
        idleWorkers.append(worker)
    }

    // MARK: - Progress and language

    /// FluidAudio only emits chunk progress for audio longer than one model window, and only finishes the
    /// session it opened for such audio, so the worker's stream is opened (before inference starts) only then.
    /// `@concurrent`: opening the file to measure it stays off the engine actor.
    @concurrent
    private static func forwardChunkProgress(
        of worker: any ParakeetWorker,
        for url: URL,
        to progress: @escaping @Sendable (Double) -> Void
    ) async -> Task<Void, Never>? {
        guard let samples = estimatedSampleCount(of: url), samples > ASRConstants.maxModelSamples else {
            return nil
        }
        let stream = await worker.transcriptionProgressStream
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

// MARK: - LiveSpeechSessionProviding (M2)

extension ParakeetEngine: LiveSpeechSessionProviding {
    /// A tail-window preview (every ~1 s over the last 15 s), or nil when the model is not on disk. Never downloads.
    public func makeLiveSession(
        scheduler: SpeechJobScheduler, options: SpeechTranscriptionOptions
    ) async -> (any LiveSpeechSession)? {
        guard case .ready = await assetStatus() else { return nil }
        let session = TailWindowPreviewSession(scheduler: scheduler) { [weak self] window in
            guard let self else { return "" }
            return try await self.transcribePreview(window, options: options)
        }
        await session.startTicking()
        return session
    }
}
