// Ported from MacParakeet (GPL-3.0): Sources/MacParakeetCore/STT/WhisperEngine.swift @ bbae9e0e
// Changes: a ChirpCore `SpeechEngine` per variant; local-folder detection by a completion marker instead of a
// folder-name search; the language fallback (retry without a forced language when the result is empty) and the
// word mapping kept, with non-decreasing starts; progress never decreases; no optimized-variant flag in defaults.
// Review fixes (fix/asr-review): a cancelled call leaves the permit queue and the shared load at once (I1); one load at
// a time, and a delete waits for a load in flight and discards its model (M3); the tokenizer config is part of "ready".
// fix/speech-memory-fit: a load that would not fit the memory iOS lets the app use now is refused before it starts.

import ChirpCore
import Foundation

/// OpenAI Whisper on WhisperKit (Core ML), one instance per variant (M7 Step 4, plan 016). Engine id
/// `argmax.whisperkit`, variant `base` or `large-v3-turbo`, on-device.
///
/// - **Explicit downloads only.** `downloadAssets` fetches the Core ML model and its tokenizer into
///   `<modelsDirectory>/models/…` and then writes a completion marker. `assetStatus`, `prepare` and `transcribe`
///   read local files only, and `transcribe` throws `modelNotDownloaded` while the marker or a tokenizer file is
///   missing (WhisperKit would otherwise fetch the tokenizer from Hugging Face at load).
/// - **One call at a time** on the loaded pipeline (WhisperKit is not thread-safe): a FIFO permit. A call cancelled
///   while it waits for the permit, or for the shared load (a first-time Core ML compile can take minutes), stops
///   waiting at once with `CancellationError`; the running call and the load go on (contract: cancellation is honored
///   promptly).
/// - **One load at a time.** Concurrent callers share it; `unloadModels()` is refused while it runs. `deleteAssets`
///   waits for a load in flight, releases what it loaded and only then removes the files.
/// - `unloadModels()` frees the model (the benchmark between engines, a route change away from this engine).
/// - **Memory fit** (fix/speech-memory-fit): right before a load starts (never while joining one), the registry row's
///   `memoryToLoadBytes` (the first-load Core ML compile peak) is compared with what `availableMemory` says iOS lets
///   the app use now. A load that does not fit throws `SpeechEngineError.insufficientMemory` and loads nothing,
///   instead of iOS terminating the app mid-compile.
public actor WhisperKitEngine: SpeechEngine, SpeechEngineUnloading {
    public static let engineID = SpeechEngineCapabilityRegistry.whisperKitEngineID
    static let completionMarker = ".chirp-download-complete"
    /// Every tokenizer file a local load reads (`tokenizer_config.json` too: without it the local load throws and
    /// WhisperKit falls back to a Hugging Face download).
    static let tokenizerFiles = ["tokenizer.json", "tokenizer_config.json"]

    public nonisolated let variant: WhisperKitVariant
    public nonisolated let modelsDirectory: URL
    public nonisolated let descriptor: EngineDescriptor
    /// This build's registry row (`argmax.whisperkit:<variant>`).
    public nonisolated let key: SpeechEngineVariantKey

    private struct LoadJob {
        let id: UUID
        let task: Task<any WhisperKitTranscribing, any Error>
    }

    /// A load that finished for files a delete has removed meanwhile.
    private struct StaleLoad: Error {}

    private let backend: any WhisperKitBackend
    private let availableMemory: any AvailableMemoryReading
    /// One call at a time on the pipeline; a cancelled waiter gives up its place at once.
    private let permit = AsyncPermit(value: 1)
    private var pipeline: (any WhisperKitTranscribing)?
    private var loadJob: LoadJob?
    /// Bumped by `deleteAssets`: a load that finishes for an older generation is released, never kept.
    private var generation = 0
    private var deletion: Task<Void, any Error>?
    private var downloading: Task<Void, any Error>?
    private var downloadFraction: Double?
    private var lastFailure: String?
    /// A call holds the permit.
    private var busy = false

    /// - Parameter availableMemory: what iOS lets the app use now, read right before each load (the app passes
    ///   `ProcessAvailableMemory`; nil readings, as on the Mac and in the Simulator, skip the check).
    public init(
        variant: WhisperKitVariant, modelsDirectory: URL,
        availableMemory: any AvailableMemoryReading = ProcessAvailableMemory()
    ) {
        self.init(
            variant: variant, modelsDirectory: modelsDirectory, backend: LiveWhisperKitBackend(),
            availableMemory: availableMemory)
    }

    init(
        variant: WhisperKitVariant, modelsDirectory: URL, backend: any WhisperKitBackend,
        availableMemory: any AvailableMemoryReading = ProcessAvailableMemory()
    ) {
        self.variant = variant
        self.modelsDirectory = modelsDirectory
        self.backend = backend
        self.availableMemory = availableMemory
        self.descriptor = Self.descriptor(for: variant)
        self.key = SpeechEngineVariantKey(engineID: Self.engineID, variant: variant.rawValue)
    }

    public static func descriptor(for variant: WhisperKitVariant) -> EngineDescriptor {
        EngineDescriptor(
            id: engineID,
            kind: .speech,
            provider: "Argmax WhisperKit",
            displayName: variant.displayName,
            locality: .onDevice,
            license: "MIT (OpenAI Whisper weights) / MIT (WhisperKit)",
            approximateDownloadBytes: variant.approximateDownloadBytes,
            providesWordTimestamps: true,
            supportedLanguages: []
        )
    }

    // MARK: - Files

    /// `<modelsDirectory>/models/argmaxinc/whisperkit-coreml/<folder>` (WhisperKit's Hugging Face layout).
    nonisolated var modelFolder: URL {
        modelsDirectory.appendingPathComponent("models/argmaxinc/whisperkit-coreml", isDirectory: true)
            .appendingPathComponent(variant.modelFolderName, isDirectory: true)
    }

    nonisolated var tokenizerFolder: URL {
        modelsDirectory.appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent(variant.tokenizerRepo, isDirectory: true)
    }

    /// Every file a local load needs is on disk and the download finished.
    nonisolated var filesPresent: Bool {
        let manager = FileManager.default
        return manager.fileExists(atPath: modelFolder.appendingPathComponent(Self.completionMarker).path)
            && Self.tokenizerFiles.allSatisfy {
                manager.fileExists(atPath: tokenizerFolder.appendingPathComponent($0).path)
            }
    }

    // MARK: - ModelAssetManaging

    public func assetStatus() async -> ModelAssetStatus {
        if let downloadFraction { return .downloading(fraction: downloadFraction) }
        if deletion == nil, filesPresent {
            return .ready(bytesOnDisk: Self.size(of: modelFolder) + Self.size(of: tokenizerFolder))
        }
        return lastFailure.map { .failed(message: $0) } ?? .notDownloaded
    }

    public func downloadAssets(progress: @escaping @Sendable (Double) -> Void) async throws {
        // A download asked for during a delete starts once the delete has finished.
        while let deletion {
            _ = await deletion.result
        }
        if let downloading { return try await downloading.value }
        if filesPresent {
            progress(1)
            return
        }
        lastFailure = nil
        downloadFraction = 0
        let reported = MonotonicFraction(progress)
        let task = Task { [backend, variant, modelsDirectory, modelFolder] in
            try await backend.download(variant, into: modelsDirectory) { fraction in
                reported.report(fraction)
                Task { await self.setDownloadFraction(fraction) }
            }
            try Data().write(to: modelFolder.appendingPathComponent(Self.completionMarker))
            Self.excludeFromBackup(modelsDirectory)
        }
        downloading = task
        defer {
            downloading = nil
            downloadFraction = nil
        }
        do {
            try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            let message =
                "\(variant.displayName) could not be downloaded. Check the connection and try again. Details: "
                + error.localizedDescription
            lastFailure = message
            throw SpeechEngineError.underlying(message)
        }
        reported.report(1)
    }

    /// Refused while a call runs. Otherwise new loads are refused at once, a load or download in flight is waited
    /// for (its model is released), and only then are this variant's folders removed. Concurrent deletes join.
    public func deleteAssets() async throws {
        if let deletion { return try await deletion.value }
        guard !busy else {
            throw SpeechEngineError.underlying(
                "\(variant.displayName) is in use by a running job. Delete it after the job finishes.")
        }
        // Everything below up to the task runs before any suspension, so no call or load can slip in between.
        generation += 1
        let loaded = pipeline
        pipeline = nil
        let pendingLoad = loadJob?.task
        loadJob = nil
        let pendingDownload = downloading
        pendingDownload?.cancel()
        let folders = [modelFolder, tokenizerFolder]
        let task = Task {
            defer { self.deletion = nil }
            // The load may be reading the model and the download writing it: both end before anything is removed.
            _ = await pendingLoad?.result
            _ = await pendingDownload?.result
            await loaded?.unload()
            let manager = FileManager.default
            for folder in folders where manager.fileExists(atPath: folder.path) {
                try manager.removeItem(at: folder)
            }
            self.lastFailure = nil
        }
        deletion = task
        try await task.value
    }

    // MARK: - SpeechEngine

    public func prepare() async throws {
        _ = try await loadedPipeline()
    }

    public func transcribe(
        fileAt url: URL,
        options: SpeechTranscriptionOptions,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> SpeechResult {
        // Cancellable while queued: a cancelled call leaves the line at once (review I1).
        try await permit.wait()
        busy = true
        defer {
            busy = false
            permit.signal()
        }
        let pipeline = try await loadedPipeline()
        try Task.checkCancellation()
        let reported = MonotonicFraction(progress)
        let cancelled = CancellationFlag()
        let requested = Self.normalizedLanguage(options.languageHint)
        let output = try await withTaskCancellationHandler {
            var output = try await Self.run(pipeline, url, requested, reported, cancelled)
            // Upstream: a forced language that yields nothing is retried with detection.
            if requested != nil, let first = output, Self.isEmpty(first) {
                output = try await Self.run(pipeline, url, nil, reported, cancelled)
            }
            return output
        } onCancel: {
            cancelled.set()
        }
        guard let output, !cancelled.isSet else { throw CancellationError() }
        try Task.checkCancellation()
        let result = try Self.makeResult(from: output, variant: variant)
        reported.report(1)
        return result
    }

    // MARK: - SpeechEngineUnloading

    /// Frees the loaded model. Refused (silently) while a call holds it, while a load or a delete runs.
    public func unloadModels() async {
        guard !busy, loadJob == nil, deletion == nil, let loaded = pipeline else { return }
        pipeline = nil
        await loaded.unload()
    }

    // MARK: - Loading

    /// The loaded pipeline, loading it from local files once. Concurrent callers share one load; a caller cancelled
    /// while it waits stops waiting at once (`CancellationError`) and the load goes on for the others and the next
    /// call. Never downloads. A new load that would not fit the memory iOS lets the app use now is refused
    /// (`insufficientMemory`) before it starts; a caller joining a load already running is not checked again.
    private func loadedPipeline() async throws -> any WhisperKitTranscribing {
        if let pipeline { return pipeline }
        guard deletion == nil, downloading == nil, filesPresent else {
            throw SpeechEngineError.modelNotDownloaded(Self.engineID)
        }
        let job: LoadJob
        if let loadJob {
            job = loadJob
        } else {
            // Before anything is read into memory or compiled: iOS terminates an app that crosses its limit.
            try SpeechEngineCapabilityRegistry.checkMemoryFit(for: key, reader: availableMemory)
            let id = UUID()
            let startGeneration = generation
            let task = Task {
                [backend, variant, modelFolder, modelsDirectory] () async throws -> any WhisperKitTranscribing in
                defer { self.clearLoadJob(id) }
                let loaded = try await backend.load(variant, modelFolder: modelFolder, tokenizerBase: modelsDirectory)
                // A delete ran while the model loaded: it belongs to removed files. Release it, never keep it.
                guard self.generation == startGeneration else {
                    await loaded.unload()
                    throw StaleLoad()
                }
                self.pipeline = loaded
                return loaded
            }
            job = LoadJob(id: id, task: task)
            loadJob = job
        }
        do {
            return try await awaitSharedTask(job.task)
        } catch {
            if error is CancellationError { throw error }
            if error is StaleLoad { throw SpeechEngineError.modelNotDownloaded(Self.engineID) }
            throw SpeechEngineError.underlying(
                "\(variant.displayName) could not be loaded. Delete it and download it again. Details: "
                    + error.localizedDescription)
        }
    }

    private func clearLoadJob(_ id: UUID) {
        if loadJob?.id == id { loadJob = nil }
    }

    private func setDownloadFraction(_ fraction: Double) {
        guard downloading != nil else { return }
        downloadFraction = max(downloadFraction ?? 0, min(max(fraction, 0), 1))
    }

    // MARK: - Result mapping

    private static func run(
        _ pipeline: any WhisperKitTranscribing, _ url: URL, _ language: String?, _ reported: MonotonicFraction,
        _ cancelled: CancellationFlag
    ) async throws -> WhisperKitOutput? {
        do {
            return try await pipeline.transcribe(
                fileAt: url.path, language: language, progress: { reported.report($0) },
                shouldContinue: { !cancelled.isSet })
        } catch {
            if cancelled.isSet || error is CancellationError { throw CancellationError() }
            throw SpeechEngineError.underlying("Whisper could not transcribe this audio: \(error.localizedDescription)")
        }
    }

    static func isEmpty(_ output: WhisperKitOutput) -> Bool {
        output.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && output.words.isEmpty
    }

    /// Whisper wants a bare language code ("en"); nil or "auto" lets it detect.
    static func normalizedLanguage(_ hint: String?) -> String? {
        guard let hint = hint?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !hint.isEmpty,
            hint != "auto"
        else { return nil }
        return hint.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init)
    }

    /// Text trimmed; words trimmed, in milliseconds, non-decreasing starts, `endMs >= startMs`, confidence 0…1.
    static func makeResult(from output: WhisperKitOutput, variant: WhisperKitVariant) throws -> SpeechResult {
        let text = output.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw SpeechEngineError.emptyTranscript }
        var words: [WordTimestamp] = []
        var lastStart = 0
        for word in output.words {
            let trimmed = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let start = max(lastStart, milliseconds(word.startSeconds))
            let end = max(start, milliseconds(word.endSeconds))
            let confidence = word.probability.isFinite ? min(1, max(0, Double(word.probability))) : 0
            words.append(WordTimestamp(word: trimmed, startMs: start, endMs: end, confidence: confidence))
            lastStart = start
        }
        return SpeechResult(
            text: text, words: words, language: output.language, engineID: engineID, engineVariant: variant.rawValue)
    }

    private static func milliseconds(_ seconds: Float) -> Int {
        guard seconds.isFinite else { return 0 }
        return max(0, Int((Double(seconds) * 1_000).rounded()))
    }

    static func size(of folder: URL) -> Int64 {
        guard
            let enumerator = FileManager.default.enumerator(
                at: folder, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey])
        else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true { total += Int64(values?.totalFileAllocatedSize ?? 0) }
        }
        return total
    }

    static func excludeFromBackup(_ folder: URL) {
        var url = folder
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }
}

/// Forwards progress in 0…1, never lower than a value already reported.
final class MonotonicFraction: @unchecked Sendable {
    // @unchecked Sendable: `last` is only touched while `lock` is held.
    private let lock = NSLock()
    private var last = -1.0
    private let forward: @Sendable (Double) -> Void

    init(_ forward: @escaping @Sendable (Double) -> Void) {
        self.forward = forward
    }

    func report(_ value: Double) {
        guard value.isFinite else { return }
        let next: Double? = lock.withLock {
            let clamped = min(1, max(0, value))
            guard clamped > last else { return nil }
            last = clamped
            return clamped
        }
        if let next { forward(next) }
    }
}

/// Set once when the job is cancelled; read from WhisperKit's callback.
final class CancellationFlag: @unchecked Sendable {
    // @unchecked Sendable: `value` is only touched while `lock` is held.
    private let lock = NSLock()
    private var value = false

    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}
