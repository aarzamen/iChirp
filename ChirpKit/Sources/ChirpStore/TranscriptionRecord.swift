// Ported from MacParakeet (GPL-3.0): Sources/MacParakeetCore/Models/Transcription.swift @ bbae9e0e
// Changes: instead of making ChirpCore's `Transcription` itself conform to GRDB's
// FetchableRecord/PersistableRecord (which would put a GRDB dependency in ChirpCore),
// `TranscriptionRecord` is a ChirpStore-private mirror with one column per `Transcription`
// field and explicit JSON-TEXT encoding for the array/struct fields, matching upstream's
// column shape.

import ChirpCore
import Foundation
import GRDB

/// Errors converting between a `transcriptions` row and `Transcription`.
enum TranscriptionRecordError: Error, Equatable {
    case invalidSourceType(String)
    case invalidStatus(String)
    case invalidPrivacyClass(String)
}

/// The `transcriptions` table row. One column per `Transcription` field; `wordTimestamps`,
/// `speakers`, `diarizationSegments` and `transcriptSegments` are stored as JSON TEXT.
struct TranscriptionRecord: Codable, Equatable, Sendable {
    var id: UUID
    var createdAt: Date
    var updatedAt: Date
    var sourceType: String
    var fileName: String
    var mediaRelativePath: String?
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
    func toTranscription() throws -> Transcription {
        guard let sourceTypeValue = Transcription.SourceType(rawValue: sourceType) else {
            throw TranscriptionRecordError.invalidSourceType(sourceType)
        }
        guard let statusValue = Transcription.Status(rawValue: status) else {
            throw TranscriptionRecordError.invalidStatus(status)
        }
        guard let privacyClassValue = PrivacyClass(rawValue: privacyClass) else {
            throw TranscriptionRecordError.invalidPrivacyClass(privacyClass)
        }

        var transcription = Transcription(
            id: id,
            createdAt: createdAt,
            sourceType: sourceTypeValue,
            fileName: fileName,
            mediaRelativePath: mediaRelativePath,
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
