// Ported from MacParakeet (GPL-3.0): Sources/MacParakeetCore/Models/Transcription.swift @ bbae9e0e
// Changes: instead of making ChirpCore's `Transcription` itself conform to GRDB's
// FetchableRecord/PersistableRecord (which would put a GRDB dependency in ChirpCore),
// `TranscriptionRecord` is a ChirpStore-private mirror with one column per `Transcription`
// field and explicit JSON-TEXT encoding for the array/struct fields, matching upstream's
// column shape.

import ChirpCore
import Foundation
import GRDB

/// The `transcriptions` table row. One column per `Transcription` field; `wordTimestamps`,
/// `speakers`, `diarizationSegments` and `transcriptSegments` are stored as JSON TEXT.
struct TranscriptionRecord: Codable, Equatable, Sendable {
    var id: UUID
    var createdAt: Date
    var updatedAt: Date
    var sourceType: String
    var fileName: String
    var mediaRelativePath: String?
    /// Added by migration `v2-audio-track-ordinal`; NULL on every earlier row (automatic selection).
    var audioTrackOrdinal: Int?
    var fileSizeBytes: Int?
    var durationMs: Int?
    var rawTranscript: String?
    var cleanTranscript: String?
    var wordTimestamps: String?
    var language: String?
    var speakerCount: Int?
    var speakers: String?
    var diarizationSegments: String?
    var transcriptSegments: String?
    var status: String
    var errorMessage: String?
    var engine: String?
    var engineVariant: String?
    var titleOverride: String?
    var derivedTitle: String?
    var derivedSnippet: String?
    var isFavorite: Bool
    var privacyClass: String
    /// Added by migration `v5-meetings` (M3); NULL / false / NULL on every earlier row.
    var userNotes: String?
    var isPartialAudio: Bool
    var audioRemovedAt: Date?
    // Added by migration `v6-documents` (M5); NULL on every earlier row. `documentPages` is JSON TEXT.
    var sourceURL: String?
    var sourceTitle: String?
    var documentFormat: String?
    var documentPages: String?
    /// Added by migration `v11-transcript-corrections` (plan 025); NULL on every earlier row. JSON TEXT
    /// (`TranscriptCorrections`), written only by `updateTextCorrections` and kept by `savePreservingUserMetadata`.
    var textCorrections: String?
}

extension TranscriptionRecord: FetchableRecord, PersistableRecord {
    static let databaseTableName = "transcriptions"
}

// MARK: - Transcription bridging

extension TranscriptionRecord {
    /// Builds the row for `transcription`, JSON-encoding its array/struct fields.
    init(_ transcription: Transcription) throws {
        id = transcription.id
        createdAt = transcription.createdAt
        updatedAt = transcription.updatedAt
        sourceType = transcription.sourceType.rawValue
        fileName = transcription.fileName
        mediaRelativePath = transcription.mediaRelativePath
        audioTrackOrdinal = transcription.audioTrackOrdinal
        fileSizeBytes = transcription.fileSizeBytes
        durationMs = transcription.durationMs
        rawTranscript = transcription.rawTranscript
        cleanTranscript = transcription.cleanTranscript
        wordTimestamps = try Self.encodeJSON(transcription.wordTimestamps)
        language = transcription.language
        speakerCount = transcription.speakerCount
        speakers = try Self.encodeJSON(transcription.speakers)
        diarizationSegments = try Self.encodeJSON(transcription.diarizationSegments)
        transcriptSegments = try Self.encodeJSON(transcription.transcriptSegments)
        status = transcription.status.rawValue
        errorMessage = transcription.errorMessage
        engine = transcription.engine
        engineVariant = transcription.engineVariant
        titleOverride = transcription.titleOverride
        derivedTitle = transcription.derivedTitle
        derivedSnippet = transcription.derivedSnippet
        isFavorite = transcription.isFavorite
        privacyClass = transcription.privacyClass.rawValue
        userNotes = transcription.userNotes
        isPartialAudio = transcription.isPartialAudio
        audioRemovedAt = transcription.audioRemovedAt
        sourceURL = transcription.sourceURL
        sourceTitle = transcription.sourceTitle
        documentFormat = transcription.documentFormat?.rawValue
        documentPages = try Self.encodeJSON(transcription.documentPages)
        textCorrections = try Self.encodeCorrections(transcription.textCorrections)
    }

    /// Decodes this row back into a `Transcription`.
    ///
    /// An enum value this build does not know (a newer build wrote it) never makes the row unreadable: it reads as
    /// `fallbackSourceType`, `fallbackStatus` or `fallbackPrivacyClass`. A JSON column that cannot be decoded still
    /// throws; list reads skip such a row (see `GRDBTranscriptionStore.decodeRows`).
    func toTranscription() throws -> Transcription {
        let sourceTypeValue = Transcription.SourceType(rawValue: sourceType) ?? Self.fallbackSourceType
        let statusValue = Transcription.Status(rawValue: status) ?? Self.fallbackStatus
        let privacyClassValue = PrivacyClass(rawValue: privacyClass) ?? Self.fallbackPrivacyClass
        if sourceTypeValue.rawValue != sourceType || statusValue.rawValue != status
            || privacyClassValue.rawValue != privacyClass
        {
            Self.logger.info("row_unknown_enum_value_read_as_fallback id=\(id, privacy: .public)")
        }

        var transcription = Transcription(
            id: id,
            createdAt: createdAt,
            sourceType: sourceTypeValue,
            fileName: fileName,
            mediaRelativePath: mediaRelativePath,
            audioTrackOrdinal: audioTrackOrdinal,
            fileSizeBytes: fileSizeBytes,
            durationMs: durationMs,
            status: statusValue,
            privacyClass: privacyClassValue
        )
        transcription.updatedAt = updatedAt
        transcription.rawTranscript = rawTranscript
        transcription.cleanTranscript = cleanTranscript
        transcription.wordTimestamps = try Self.decodeJSON([WordTimestamp].self, from: wordTimestamps)
        transcription.language = language
        transcription.speakerCount = speakerCount
        transcription.speakers = try Self.decodeJSON([SpeakerInfo].self, from: speakers)
        transcription.diarizationSegments = try Self.decodeJSON(
            [DiarizationSegmentRecord].self, from: diarizationSegments
        )
        transcription.transcriptSegments = try Self.decodeJSON(
            [TranscriptSegmentRecord].self, from: transcriptSegments
        )
        transcription.errorMessage = errorMessage
        transcription.engine = engine
        transcription.engineVariant = engineVariant
        transcription.titleOverride = titleOverride
        transcription.derivedTitle = derivedTitle
        transcription.derivedSnippet = derivedSnippet
        transcription.isFavorite = isFavorite
        transcription.userNotes = userNotes
        transcription.isPartialAudio = isPartialAudio
        transcription.audioRemovedAt = audioRemovedAt
        transcription.sourceURL = sourceURL
        transcription.sourceTitle = sourceTitle
        // An unknown format (a newer build wrote it) reads as nil; writing the row back keeps the stored value.
        transcription.documentFormat = documentFormat.flatMap(DocumentFormat.init(rawValue:))
        transcription.documentPages = try Self.decodeJSON([DocumentPage].self, from: documentPages)
        transcription.textCorrections = Self.decodeCorrections(textCorrections, id: id)
        return transcription
    }

    // MARK: Corrections (plan 025)

    /// The column for `corrections`. A newer build's envelope (a placeholder here) is never encoded: every write path
    /// keeps the stored text instead (`preservedCorrections`, `GRDBTranscriptionStore.updateTextCorrections`).
    static func encodeCorrections(_ corrections: TranscriptCorrections?) throws -> String? {
        guard let corrections, !corrections.isFromNewerBuild else { return nil }
        return try encodeJSON(corrections)
    }

    /// Reads the column. One that cannot be decoded never hides the row: it reads as a placeholder that applies
    /// nothing and that no write replaces (like a newer build's), and is logged by row id only.
    static func decodeCorrections(_ json: String?, id: UUID) -> TranscriptCorrections? {
        guard let json else { return nil }
        do {
            return try decodeJSON(TranscriptCorrections.self, from: json)
        } catch {
            logger.error("corrections_unreadable id=\(id, privacy: .public)")
            return TranscriptCorrections(
                schema: TranscriptCorrections.currentSchema + 1, baseline: "", changedAt: .distantPast)
        }
    }

    /// What a pipeline save stores in the column (plan 025 D7): the stored corrections, kept attached while
    /// `newWords` are the words they were made against and detached when the words changed; the stored text byte for
    /// byte when nothing changed or this build cannot read it. `stillApplied` is true when items remain attached, so
    /// the stored (corrected) title and snippet stay.
    static func preservedCorrections(stored: String?, newWords: [WordTimestamp], id: UUID, now: Date) throws -> (
        column: String?, stillApplied: Bool
    ) {
        guard let corrections = decodeCorrections(stored, id: id), !corrections.isFromNewerBuild else {
            return (stored, false)
        }
        let preserved = corrections.preserved(acrossNewWords: newWords, now: now)
        let column = preserved == corrections ? stored : try encodeCorrections(preserved)
        return (column, !preserved.items.isEmpty)
    }

    // MARK: Unknown enum values

    /// What an unknown `sourceType` reads as: the generic imported-file kind.
    static let fallbackSourceType = Transcription.SourceType.file
    /// What an unknown `status` reads as: a terminal status the UI already renders, with Retry.
    static let fallbackStatus = Transcription.Status.interrupted
    /// What an unknown `privacyClass` reads as: the most protective class, so routing stays on-device.
    static let fallbackPrivacyClass = PrivacyClass.clinical

    private static let logger = Log.logger("store")

    /// This record with `stored`'s enum raw values put back wherever `stored` held a value this build does not know
    /// and this record still carries the fallback it read as (`savePreservingUserMetadata`, the one whole-row write).
    /// A job finishing on an older build therefore never overwrites a newer build's value; an explicit change still
    /// lands. The field-level writes never rewrite those columns at all (`GRDBTranscriptionStore.updateColumns`).
    func keepingUnknownRawValues(of stored: TranscriptionRecord?) -> TranscriptionRecord {
        guard let stored else { return self }
        var result = self
        if Transcription.SourceType(rawValue: stored.sourceType) == nil,
            sourceType == Self.fallbackSourceType.rawValue
        {
            result.sourceType = stored.sourceType
        }
        if Transcription.Status(rawValue: stored.status) == nil, status == Self.fallbackStatus.rawValue {
            result.status = stored.status
        }
        if PrivacyClass(rawValue: stored.privacyClass) == nil, privacyClass == Self.fallbackPrivacyClass.rawValue {
            result.privacyClass = stored.privacyClass
        }
        if let storedFormat = stored.documentFormat, DocumentFormat(rawValue: storedFormat) == nil,
            documentFormat == nil
        {
            result.documentFormat = storedFormat
        }
        return result
    }

    // MARK: JSON columns

    private static func encodeJSON<T: Encodable>(_ value: T?) throws -> String? {
        guard let value else { return nil }
        let data = try JSONEncoder().encode(value)
        return String(decoding: data, as: UTF8.self)
    }

    private static func decodeJSON<T: Decodable>(_ type: T.Type, from json: String?) throws -> T? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

// MARK: - Renaming a speaker inside the stored JSON

/// Renames one speaker inside the stored `speakers` and `transcriptSegments` JSON text through `JSONSerialization`,
/// so every key a newer build wrote survives (review R1-2). The rule is `Transcription.renameSpeaker`'s: the roster
/// entry whose `id` is `speakerId` gets the new `label`, and each segment of that speaker the new `speakerLabel`.
enum StoredSpeakerRename {
    /// The two columns after the rename, or nil when the roster has no such speaker (nothing to write). Throws when a
    /// column is not a JSON array, as decoding it would.
    static func renaming(
        _ speakerId: String, to name: String, speakers: String?, segments: String?
    ) throws -> (speakers: String, segments: String?)? {
        guard let speakers else { return nil }
        var roster = try jsonArray(speakers)
        guard let index = roster.firstIndex(where: { ($0 as? [String: Any])?["id"] as? String == speakerId }),
            var speaker = roster[index] as? [String: Any]
        else { return nil }
        speaker["label"] = name
        roster[index] = speaker
        guard let segments else { return (try jsonText(roster), nil) }
        var list = try jsonArray(segments)
        for position in list.indices {
            guard var segment = list[position] as? [String: Any], segment["speakerId"] as? String == speakerId
            else { continue }
            segment["speakerLabel"] = name
            list[position] = segment
        }
        return (try jsonText(roster), try jsonText(list))
    }

    private static func jsonArray(_ text: String) throws -> [Any] {
        guard let array = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [Any] else {
            throw DecodingError.typeMismatch(
                [Any].self, .init(codingPath: [], debugDescription: "A JSON column is not an array."))
        }
        return array
    }

    private static func jsonText(_ array: [Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: array), as: UTF8.self)
    }
}
