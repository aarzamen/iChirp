// Ported from MacParakeet (GPL-3.0): Sources/MacParakeetCore/STT/WhisperEngine.swift @ bbae9e0e
// Changes: WhisperKit 0.18 → argmax-oss-swift 1.1.0; download also fetches the tokenizer (WhisperKit would otherwise
// fetch it from Hugging Face on first load); VAD chunking with incremental file loading and two concurrent windows
// (iPhone memory); special tokens skipped; cancellation stops decoding through the callback. The language fallback
// and the word mapping live in `WhisperKitEngine`. Review fixes: progress is the share of the file decoded (from
// WhisperKit's segment callback) instead of a fixed 50 %; the load reads the tokenizer from local files first and
// refuses when that fails, so WhisperKit never falls back to fetching it.

import AVFoundation
import Foundation
import WhisperKit

/// `WhisperKitBackend` on WhisperKit (`argmax-oss-swift` 1.1.0).
struct LiveWhisperKitBackend: WhisperKitBackend {
    /// Windows decoded at once. Upstream uses WhisperKit's default (16) on the Mac; iPhone memory wants fewer.
    static let concurrentWindows = 2

    func download(
        _ variant: WhisperKitVariant, into base: URL, progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        _ = try await WhisperKit.download(
            variant: variant.modelFolderName, downloadBase: base,
            progressCallback: { value in progress(0.97 * value.fractionCompleted) })
        // Downloads `tokenizer.json` and friends into `<base>/models/<tokenizerRepo>` (and loads them once).
        _ = try await ModelUtilities.loadTokenizer(for: Self.tokenizerVariant(variant), tokenizerFolder: base)
        progress(1)
    }

    func load(
        _ variant: WhisperKitVariant, modelFolder: URL, tokenizerBase: URL
    ) async throws -> any WhisperKitTranscribing {
        // WhisperKit loads the tokenizer from this folder and, when that throws (a damaged file), downloads it from
        // Hugging Face without asking. Read it here first, from local files only, and refuse instead.
        let tokenizerFolder = tokenizerBase.appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent(variant.tokenizerRepo, isDirectory: true)
        do {
            _ = try await AutoTokenizerWrapper.from(modelFolder: tokenizerFolder)
        } catch {
            throw WhisperKitLoadError.tokenizerUnreadable(error.localizedDescription)
        }
        let config = WhisperKitConfig(
            downloadBase: tokenizerBase, modelFolder: modelFolder.path, tokenizerFolder: tokenizerBase,
            verbose: false, logLevel: .none, prewarm: false, load: true, download: false)
        return LoadedWhisperKit(kit: try await WhisperKit(config))
    }

    /// The file's length in seconds (the normalized 16 kHz WAV), or nil when it cannot be read.
    static func durationSeconds(of path: String) -> Double? {
        guard let file = try? AVAudioFile(forReading: URL(fileURLWithPath: path)) else { return nil }
        let rate = file.processingFormat.sampleRate
        return rate > 0 ? Double(file.length) / rate : nil
    }

    /// The share of the file WhisperKit has decoded, from the end of the last segment it found; below 1 until the
    /// engine reports the end itself. Nil without a usable duration.
    static func audioFraction(coveredSeconds: Double, durationSeconds: Double) -> Double? {
        guard coveredSeconds.isFinite, durationSeconds.isFinite, durationSeconds > 0 else { return nil }
        return min(0.99, max(0, coveredSeconds / durationSeconds))
    }

    static func tokenizerVariant(_ variant: WhisperKitVariant) -> ModelVariant {
        switch variant {
        case .base: .base
        case .largeV3Turbo: .largev3
        }
    }
}

/// Why a local load was refused.
enum WhisperKitLoadError: LocalizedError {
    case tokenizerUnreadable(String)

    var errorDescription: String? {
        switch self {
        case .tokenizerUnreadable(let details): "The tokenizer files are damaged (\(details))."
        }
    }
}

/// One loaded pipeline. `@unchecked Sendable`: `WhisperKit` is a non-Sendable class; `WhisperKitEngine` runs one
/// call on it at a time (its permit), and the instance is never touched after `unload`.
final class LoadedWhisperKit: WhisperKitTranscribing, @unchecked Sendable {
    private let kit: WhisperKit

    init(kit: WhisperKit) {
        self.kit = kit
    }

    func transcribe(
        fileAt path: String, language: String?, progress: @escaping @Sendable (Double) -> Void,
        shouldContinue: @escaping @Sendable () -> Bool
    ) async throws -> WhisperKitOutput? {
        let options = DecodingOptions(
            task: .transcribe, language: language, usePrefillPrompt: language != nil, detectLanguage: language == nil,
            skipSpecialTokens: true, wordTimestamps: true,
            concurrentWorkerCount: LiveWhisperKitBackend.concurrentWindows, chunkingStrategy: .vad)
        // Per decoded token: only the cancellation check. Progress comes from the segments found so far (their end,
        // in file time, over the file's length); the engine reports 1 itself at the end.
        let callback: TranscriptionCallback = { _ in shouldContinue() }
        let duration = LiveWhisperKitBackend.durationSeconds(of: path)
        kit.segmentDiscoveryCallback = { segments in
            guard let duration, let end = segments.map(\.end).max(),
                let fraction = LiveWhisperKitBackend.audioFraction(
                    coveredSeconds: Double(end), durationSeconds: duration)
            else { return }
            progress(fraction)
        }
        defer { kit.segmentDiscoveryCallback = nil }
        let results = try await kit.transcribe(
            audioPath: path, audioInputOptions: AudioInputOptions(audioLoadingMode: .incremental),
            decodeOptions: options, callback: callback)
        guard shouldContinue() else { return nil }
        let merged = TranscriptionUtilities.mergeTranscriptionResults(results)
        return WhisperKitOutput(
            text: merged.text,
            words: merged.allWords.map {
                WhisperKitWord(text: $0.word, startSeconds: $0.start, endSeconds: $0.end, probability: $0.probability)
            },
            language: merged.language.isEmpty ? nil : merged.language)
    }

    func unload() async {
        await kit.unloadModels()
    }
}
