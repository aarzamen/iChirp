// Ported from MacParakeet (GPL-3.0): Sources/MacParakeetCore/STT/WhisperEngine.swift @ bbae9e0e
// Changes: a ChirpCore `SpeechEngine` per variant; local-folder detection by a completion marker instead of a
// folder-name search; the language fallback (retry without a forced language when the result is empty) and the
// word mapping kept, with non-decreasing starts; progress never decreases; no optimized-variant flag in defaults.

import ChirpCore
import Foundation

/// OpenAI Whisper on WhisperKit (Core ML), one instance per variant (M7 Step 4, plan 016). Engine id
/// `argmax.whisperkit`, variant `base` or `large-v3-turbo`, on-device.
///
/// - **Explicit downloads only.** `downloadAssets` fetches the Core ML model and its tokenizer into
///   `<modelsDirectory>/models/…` and then writes a completion marker. `assetStatus`, `prepare` and `transcribe`
///   read local files only, and `transcribe` throws `modelNotDownloaded` while the marker or the tokenizer is missing.
/// - **One call at a time** on the loaded pipeline (WhisperKit is not thread-safe): a FIFO permit inside the actor.
/// - `unloadModels()` frees the model (the benchmark does this between engines).
public actor WhisperKitEngine: SpeechEngine, SpeechEngineUnloading {
    public static let engineID = SpeechEngineCapabilityRegistry.whisperKitEngineID
    static let completionMarker = ".chirp-download-complete"

    public nonisolated let variant: WhisperKitVariant
    public nonisolated let modelsDirectory: URL
    public nonisolated let descriptor: EngineDescriptor

    private let backend: any WhisperKitBackend
    private var pipeline: (any WhisperKitTranscribing)?
    private var loading: Task<any WhisperKitTranscribing, any Error>?
    private var downloading: Task<Void, any Error>?
    private var downloadFraction: Double?
    private var lastFailure: String?
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(variant: WhisperKitVariant, modelsDirectory: URL) {
        self.init(variant: variant, modelsDirectory: modelsDirectory, backend: LiveWhisperKitBackend())
    }

    init(variant: WhisperKitVariant, modelsDirectory: URL, backend: any WhisperKitBackend) {
        self.variant = variant
        self.modelsDirectory = modelsDirectory
        self.backend = backend
        self.descriptor = Self.descriptor(for: variant)
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
            && manager.fileExists(atPath: tokenizerFolder.appendingPathComponent("tokenizer.json").path)
    }

    // MARK: - ModelAssetManaging

    public func assetStatus() async -> ModelAssetStatus {
        if let downloadFraction { return .downloading(fraction: downloadFraction) }
        if filesPresent {
            return .ready(bytesOnDisk: Self.size(of: modelFolder) + Self.size(of: tokenizerFolder))
        }
        return lastFailure.map { .failed(message: $0) } ?? .notDownloaded
    }

    public func downloadAssets(progress: @escaping @Sendable (Double) -> Void) async throws {
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

    public func deleteAssets() async throws {
        guard !busy else {
            throw SpeechEngineError.underlying(
                "\(variant.displayName) is in use by a running job. Delete it after the job finishes.")
        }
        await unloadModels()
        let manager = FileManager.default
        for folder in [modelFolder, tokenizerFolder] where manager.fileExists(atPath: folder.path) {
            try manager.removeItem(at: folder)
        }
        lastFailure = nil
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
        await acquire()
        defer { release() }
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

    public func unloadModels() async {
        guard !busy else { return }
        let loaded = pipeline
        pipeline = nil
        loading = nil
        await loaded?.unload()
    }

    // MARK: - Loading

    private func loadedPipeline() async throws -> any WhisperKitTranscribing {
        if let pipeline { return pipeline }
        guard downloading == nil, filesPresent else { throw SpeechEngineError.modelNotDownloaded(Self.engineID) }
        let task: Task<any WhisperKitTranscribing, any Error>
        if let loading {
            task = loading
        } else {
            task = Task { [backend, variant, modelFolder, modelsDirectory] in
                try await backend.load(variant, modelFolder: modelFolder, tokenizerBase: modelsDirectory)
            }
            loading = task
        }
        do {
            let loaded = try await task.value
            if loading != nil {
                pipeline = loaded
                loading = nil
            }
            return loaded
        } catch {
            loading = nil
            if error is CancellationError { throw error }
            throw SpeechEngineError.underlying(
                "\(variant.displayName) could not be loaded. Delete it and download it again. Details: "
                    + error.localizedDescription)
        }
    }

    private func setDownloadFraction(_ fraction: Double) {
        guard downloading != nil else { return }
        downloadFraction = max(downloadFraction ?? 0, min(max(fraction, 0), 1))
    }

    // MARK: - Permit (one call at a time)

    private func acquire() async {
        if !busy {
            busy = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty {
            busy = false
        } else {
            waiters.removeFirst().resume()
        }
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
