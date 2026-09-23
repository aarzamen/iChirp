import Foundation

/// The WhisperKit builds iChirp offers (registry rows `argmax.whisperkit:<rawValue>`). Variant ids are forever.
public enum WhisperKitVariant: String, CaseIterable, Sendable {
    /// `openai_whisper-base`: small and quick, 99 languages.
    case base
    /// `openai_whisper-large-v3-v20240930_turbo_632MB`: Whisper large-v3 turbo, quantized to about 632 MB.
    case largeV3Turbo = "large-v3-turbo"

    /// The model folder in `argmaxinc/whisperkit-coreml`.
    public var modelFolderName: String {
        switch self {
        case .base: "openai_whisper-base"
        case .largeV3Turbo: "openai_whisper-large-v3-v20240930_turbo_632MB"
        }
    }

    /// The Hugging Face repo WhisperKit reads the tokenizer from (not bundled with the Core ML model).
    public var tokenizerRepo: String {
        switch self {
        case .base: "openai/whisper-base"
        case .largeV3Turbo: "openai/whisper-large-v3"
        }
    }

    public var displayName: String {
        switch self {
        case .base: "Whisper Base"
        case .largeV3Turbo: "Whisper Large v3 Turbo"
        }
    }

    /// Model plus tokenizer, measured on Hugging Face (2026-09-22).
    public var approximateDownloadBytes: Int64 {
        switch self {
        case .base: 151_000_000
        case .largeV3Turbo: 650_000_000
        }
    }
}

/// One recognized word from WhisperKit (seconds from the start of the file).
struct WhisperKitWord: Sendable, Equatable {
    var text: String
    var startSeconds: Float
    var endSeconds: Float
    var probability: Float
}

/// What one WhisperKit pass returns, merged over its windows.
struct WhisperKitOutput: Sendable, Equatable {
    var text: String
    var words: [WhisperKitWord]
    var language: String?
}

/// A loaded WhisperKit pipeline. `transcribe` returns nil when `shouldContinue` stopped it (cancellation).
protocol WhisperKitTranscribing: Sendable {
    func transcribe(
        fileAt path: String, language: String?, progress: @escaping @Sendable (Double) -> Void,
        shouldContinue: @escaping @Sendable () -> Bool
    ) async throws -> WhisperKitOutput?
    func unload() async
}

/// The seam between `WhisperKitEngine` and WhisperKit (live) or a fake (tests).
protocol WhisperKitBackend: Sendable {
    /// Downloads the Core ML model and its tokenizer under `base` (Hugging Face layout `models/<repo>/…`). The only
    /// network use.
    func download(
        _ variant: WhisperKitVariant, into base: URL, progress: @escaping @Sendable (Double) -> Void
    ) async throws
    /// Loads from local files only (WhisperKit's `download: false`; the tokenizer folder must hold `tokenizer.json`).
    func load(_ variant: WhisperKitVariant, modelFolder: URL, tokenizerBase: URL) async throws
        -> any WhisperKitTranscribing
}
