import Foundation

/// The iChirp library record: one captured or imported recording and everything derived from it.
///
/// Shape follows MacParakeet's `Transcription` (upstream `Models/Transcription.swift`), trimmed to what
/// M1 persists, plus `privacyClass` for engine routing. Rows are stored by `TranscriptionStoring`.
public struct Transcription: Codable, Identifiable, Sendable, Equatable {
    public enum SourceType: String, Codable, Sendable, CaseIterable {
        case file, dictation, meeting, url, podcast, document
    }

    public enum Status: String, Codable, Sendable {
        case processing, completed, failed, interrupted, cancelled
    }

    public var id: UUID
    public var createdAt: Date
    public var updatedAt: Date
    public var sourceType: SourceType
    /// Original file name shown to the user.
    public var fileName: String
    /// Relative to `AppPaths.root`, e.g. "media/<id>/source.m4a".
    public var mediaRelativePath: String?
    /// The zero-based audio track the person chose in a multi-track file; nil means automatic (the first track, and
    /// every row from before M1.5). Reused by Retry. See `spec/contracts/file-transcription-audio-tracks-v1.md`.
    public var audioTrackOrdinal: Int?
    public var fileSizeBytes: Int?
    public var durationMs: Int?
    public var rawTranscript: String?
    public var cleanTranscript: String?
    public var wordTimestamps: [WordTimestamp]?
    public var language: String?
    public var speakerCount: Int?
    public var speakers: [SpeakerInfo]?
    public var diarizationSegments: [DiarizationSegmentRecord]?
    public var transcriptSegments: [TranscriptSegmentRecord]?
    public var status: Status
    public var errorMessage: String?
    /// `EngineDescriptor.id`, e.g. "fluidaudio.parakeet-tdt".
    public var engine: String?
    /// "v3" | "v2".
    public var engineVariant: String?
    public var titleOverride: String?
    public var derivedTitle: String?
    public var derivedSnippet: String?
    public var isFavorite: Bool
    public var privacyClass: PrivacyClass
    // M3 meetings (migration `v5-meetings`, spec/contracts/meeting-session-v1.md).
    /// What the person typed about this item (the Notes tab). A user field: pipeline saves never overwrite it.
    public var userNotes: String?
    /// A meeting recovered after the app was killed while it recorded: its audio ends where the kill happened.
    public var isPartialAudio: Bool
    /// When the meeting-audio retention setting deleted this item's audio (`mediaRelativePath` is nil since).
    public var audioRemovedAt: Date?

    /// Creates a new row. Every property not listed here starts empty: optionals are nil, `isFavorite` is
    /// false and `updatedAt` equals `createdAt`.
    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        sourceType: SourceType = .file,
        fileName: String,
        mediaRelativePath: String? = nil,
        audioTrackOrdinal: Int? = nil,
        fileSizeBytes: Int? = nil,
        durationMs: Int? = nil,
        status: Status = .processing,
        privacyClass: PrivacyClass = .personal
    ) {
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.sourceType = sourceType
        self.fileName = fileName
        self.mediaRelativePath = mediaRelativePath
        self.audioTrackOrdinal = audioTrackOrdinal
        self.fileSizeBytes = fileSizeBytes
        self.durationMs = durationMs
        self.status = status
        self.isFavorite = false
        self.privacyClass = privacyClass
        self.isPartialAudio = false
    }

    /// titleOverride ?? non-empty derivedTitle ?? fileName without extension
    public var displayTitle: String {
        if let override = Self.nonBlank(titleOverride) {
            return override
        }
        if let derived = Self.nonBlank(derivedTitle) {
            return derived
        }
        return (fileName as NSString).deletingPathExtension
    }

    /// cleanTranscript when non-empty, else rawTranscript, else ""
    public var displayText: String {
        if let clean = cleanTranscript, Self.nonBlank(clean) != nil {
            return clean
        }
        return rawTranscript ?? ""
    }

    /// The trimmed value, or nil when it is nil or only whitespace.
    private static func nonBlank(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

extension Transcription {
    /// The trimmed name a rename may store: nil for blank input (a speaker keeps a label; "Speaker 1" is restored by
    /// renaming it back).
    public static func speakerName(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(60))
    }

    /// Renames speaker `speakerId` to `label` in `speakers` and in every transcript segment of that speaker (M3).
    /// Returns false, changing nothing, when the speaker is not in `speakers` or the name is blank.
    @discardableResult
    public mutating func renameSpeaker(_ speakerId: String, to label: String) -> Bool {
        guard let name = Self.speakerName(label),
            let index = speakers?.firstIndex(where: { $0.id == speakerId })
        else { return false }
        speakers?[index].label = name
        if let segments = transcriptSegments {
            transcriptSegments = segments.map { segment in
                guard segment.speakerId == speakerId else { return segment }
                var renamed = segment
                renamed.speakerLabel = name
                return renamed
            }
        }
        return true
    }
}
