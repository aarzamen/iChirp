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
        return transcription
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
    /// and this record still carries the fallback it read as. A rename or favorite made on an older build therefore
    /// never overwrites a newer build's value; an explicit change (a Retry moving the status) still lands.
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
