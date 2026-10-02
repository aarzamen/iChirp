// Ported from MacParakeet (GPL-3.0): Sources/MacParakeetCore/Models/Transcription.swift @ bbae9e0e
// Changes: L255–L360 only; dropped anchorTranscriptSegmentIDs, updatingSpeakerLabels and carriesAutomaticLabel (no
// speaker renaming prompts). `isTextEdited` is re-ported as an optional (plan 025): only the corrected segments the
// accessor projects for the JSON export set it; stored segments never do.

import Foundation

/// One recognized word with its timing in milliseconds from the start of the source audio.
public struct WordTimestamp: Codable, Sendable, Equatable {
    public var word: String
    public var startMs: Int
    public var endMs: Int
    public var confidence: Double
    public var speakerId: String?

    public init(word: String, startMs: Int, endMs: Int, confidence: Double, speakerId: String? = nil) {
        self.word = word
        self.startMs = startMs
        self.endMs = endMs
        self.confidence = confidence
        self.speakerId = speakerId
    }
}

/// A diarized speaker: a stable id ("S1") and the label shown to the user ("Speaker 1").
public struct SpeakerInfo: Codable, Sendable, Equatable {
    public var id: String
    public var label: String

    public init(id: String, label: String) {
        self.id = id
        self.label = label
    }
}

/// A span of audio attributed to one speaker by diarization.
public struct DiarizationSegmentRecord: Codable, Sendable, Equatable {
    public var speakerId: String
    public var startMs: Int
    public var endMs: Int

    public init(speakerId: String, startMs: Int, endMs: Int) {
        self.speakerId = speakerId
        self.startMs = startMs
        self.endMs = endMs
    }
}

/// Half-open index range into `Transcription.wordTimestamps`.
public struct TranscriptSegmentWordRange: Codable, Sendable, Equatable, Hashable {
    public var startIndex: Int
    public var endIndexExclusive: Int

    public init(startIndex: Int, endIndexExclusive: Int) {
        self.startIndex = startIndex
        self.endIndexExclusive = endIndexExclusive
    }
}

/// A speaker-attributed transcript segment materialized from words plus diarization.
public struct TranscriptSegmentRecord: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var startMs: Int
    public var endMs: Int
    public var speakerId: String?
    public var speakerLabel: String
    public var text: String
    public var wordRange: TranscriptSegmentWordRange
    /// True when a correction lies inside the segment (plan 025). Nil (omitted from JSON) otherwise.
    public var isTextEdited: Bool?

    public init(
        id: UUID = UUID(),
        startMs: Int,
        endMs: Int,
        speakerId: String?,
        speakerLabel: String,
        text: String,
        wordRange: TranscriptSegmentWordRange,
        isTextEdited: Bool? = nil
    ) {
        self.id = id
        self.startMs = startMs
        self.endMs = endMs
        self.speakerId = speakerId
        self.speakerLabel = speakerLabel
        self.text = text
        self.wordRange = wordRange
        self.isTextEdited = isTextEdited
    }
}
