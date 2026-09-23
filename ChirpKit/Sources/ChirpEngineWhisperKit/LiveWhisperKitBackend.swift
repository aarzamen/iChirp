// Ported from MacParakeet (GPL-3.0): Sources/MacParakeetCore/STT/WhisperEngine.swift @ bbae9e0e
// Changes: WhisperKit 0.18 → argmax-oss-swift 1.1.0; download also fetches the tokenizer (WhisperKit would otherwise
// fetch it from Hugging Face on first load); VAD chunking with incremental file loading and two concurrent windows
// (iPhone memory); special tokens skipped; cancellation stops decoding through the callback. The language fallback
// and the word mapping live in `WhisperKitEngine`.

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
        let config = WhisperKitConfig(
            downloadBase: tokenizerBase, modelFolder: modelFolder.path, tokenizerFolder: tokenizerBase,
            verbose: false, logLevel: .none, prewarm: false, load: true, download: false)
        return LoadedWhisperKit(kit: try await WhisperKit(config))
    }

    static func tokenizerVariant(_ variant: WhisperKitVariant) -> ModelVariant {
        switch variant {
        case .base: .base
        case .largeV3Turbo: .largev3
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
        let callback: TranscriptionCallback = { _ in
            progress(0.5)
            return shouldContinue()
        }
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
