import Foundation

/// What a transcription is for. Engines may tune for it; the result's shape never changes.
public enum SpeechTranscriptionPurpose: String, Sendable, Equatable {
    /// An imported file or a meeting: any length.
    case file
    /// A dictation's final pass (M2): usually a short clip that ends right after the last word. Parakeet appends
    /// 0.5 s of silence to a clip that fits one model window so the last word is not clipped (upstream STTRuntime).
    case dictation
}

/// Per-call options for `SpeechEngine.transcribe`.
public struct SpeechTranscriptionOptions: Sendable, Equatable {
    /// BCP-47 hint; nil lets the engine detect the language.
    public var languageHint: String?
    /// Added in M2 (additive; defaults to `.file`).
    public var purpose: SpeechTranscriptionPurpose

    public init(languageHint: String? = nil, purpose: SpeechTranscriptionPurpose = .file) {
        self.languageHint = languageHint
        self.purpose = purpose
    }
}

/// What a speech engine returns for one file.
public struct SpeechResult: Sendable, Equatable {
    public var text: String
    public var words: [WordTimestamp]
    public var language: String?
    public var engineID: String
    public var engineVariant: String?

    public init(text: String, words: [WordTimestamp], language: String?, engineID: String, engineVariant: String?) {
        self.text = text
        self.words = words
        self.language = language
        self.engineID = engineID
        self.engineVariant = engineVariant
    }
}

/// A speech-to-text engine plug-in. Conformers live in their own targets (e.g. ChirpEngineFluidAudio).
public protocol SpeechEngine: ModelAssetManaging {
    var descriptor: EngineDescriptor { get }
    /// Loads models into memory (after assets exist). Idempotent.
    func prepare() async throws
    /// `fileAt` must be 16 kHz mono PCM (the AudioNormalizing output).
    func transcribe(
        fileAt url: URL,
        options: SpeechTranscriptionOptions,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> SpeechResult
}

/// What a diarizer returns for one file.
public struct DiarizationOutput: Sendable, Equatable {
    /// Chronological, ids "S1"…"Sn" by first speech.
    public var segments: [DiarizationSegmentRecord]
    /// Labels "Speaker 1"…
    public var speakers: [SpeakerInfo]

    public init(segments: [DiarizationSegmentRecord], speakers: [SpeakerInfo]) {
        self.segments = segments
        self.speakers = speakers
    }
}

/// A speaker diarization plug-in ("who spoke when").
public protocol SpeakerDiarizing: ModelAssetManaging {
    var descriptor: EngineDescriptor { get }
    func diarize(fileAt url: URL) async throws -> DiarizationOutput
}

/// Errors every speech or diarization engine maps its failures onto.
public enum SpeechEngineError: Error, Equatable, LocalizedError {
    case modelNotDownloaded(String)
    case emptyTranscript
    case cancelled
    case underlying(String)

    public var errorDescription: String? {
        switch self {
        case .modelNotDownloaded(let engineID):
            // Carries the engine id (contract), so the sentence names it as a detail rather than as a model name.
            return "A model this needs hasn't been downloaded yet (\(engineID)). Download it in Settings."
        case .emptyTranscript:
            return "No speech was recognized in this recording."
        case .cancelled:
            return "Transcription was cancelled."
        case .underlying(let message):
            return message
        }
    }
}
