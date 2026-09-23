// New in iChirp (M6, plan 015): the structure-model evidence ledger. No upstream source.
// Contract: spec/contracts/structured-results-v1.md.

import ChirpCore
import Foundation
import GRDB

/// The M6 tables. Called once, from the "v7-structured-results" migration; never edited after it ships.
enum StructuredResultsSchema {
    static func create(_ db: Database) throws {
        // One extraction run over one transcript. Deleting the transcript (an explicit user flow) deletes its runs.
        try db.create(table: "structured_runs") { t in
            t.column("id", .text).primaryKey()
            t.column("transcriptionId", .text).notNull().references("transcriptions", onDelete: .cascade)
            t.column("catalogVersion", .text).notNull()
            t.column("engineId", .text).notNull()
            t.column("modelSha256", .text)
            t.column("actThreshold", .double).notNull()
            t.column("provisionalThreshold", .double).notNull()
            t.column("createdAt", .datetime).notNull()
        }
        try db.create(
            index: "idx_structured_runs_transcription_created", on: "structured_runs",
            columns: ["transcriptionId", "createdAt"])

        // One field of a run with its evidence: the source span (characters, words, milliseconds), confidence, the
        // gate's verdict and whether the person reviewed it. Local database only (like the transcript itself).
        try db.create(table: "structured_fields") { t in
            t.column("id", .text).primaryKey()
            t.column("runId", .text).notNull().references("structured_runs", onDelete: .cascade)
            t.column("ordinal", .integer).notNull()
            t.column("tool", .text).notNull()
            t.column("argumentsJson", .text).notNull()
            t.column("spanCharStart", .integer).notNull()
            t.column("spanCharEnd", .integer).notNull()
            t.column("spanWordStart", .integer)
            t.column("spanWordEnd", .integer)
            t.column("spanStartMs", .integer)
            t.column("spanEndMs", .integer)
            t.column("confidence", .double).notNull()
            t.column("verdict", .text).notNull()
            t.column("reviewReasons", .text).notNull().defaults(to: "[]")
            t.column("reviewed", .boolean).notNull().defaults(to: false)
            t.column("reviewedAt", .datetime)
        }
        try db.create(index: "idx_structured_fields_run", on: "structured_fields", columns: ["runId", "ordinal"])

        // Eval runs over the synthetic cases (Settings → Structure models → Eval). Synthetic content only.
        try db.create(table: "structured_eval_runs") { t in
            t.column("id", .text).primaryKey()
            t.column("engineId", .text).notNull()
            t.column("modelSha256", .text)
            t.column("catalogVersion", .text).notNull()
            t.column("caseCount", .integer).notNull()
            t.column("toolShapeAccuracy", .double).notNull()
            t.column("argumentAccuracy", .double).notNull()
            t.column("numericHardFails", .integer).notNull()
            t.column("reportJson", .text).notNull()
            t.column("createdAt", .datetime).notNull()
        }
    }
}

struct StructuredRunRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "structured_runs"
    var id: UUID
    var transcriptionId: UUID
    var catalogVersion: String
    var engineId: String
    var modelSha256: String?
    var actThreshold: Double
    var provisionalThreshold: Double
    var createdAt: Date

    init(_ run: StructuredRun) {
        id = run.id
        transcriptionId = run.transcriptionID
        catalogVersion = run.catalogVersion
        engineId = run.engineID
        modelSha256 = run.modelSHA256
        actThreshold = run.actThreshold
        provisionalThreshold = run.provisionalThreshold
        createdAt = run.createdAt
    }

    var run: StructuredRun {
        StructuredRun(
            id: id, transcriptionID: transcriptionId, catalogVersion: catalogVersion, engineID: engineId,
            modelSHA256: modelSha256, actThreshold: actThreshold, provisionalThreshold: provisionalThreshold,
            createdAt: createdAt)
    }
}

struct StructuredFieldRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "structured_fields"
    var id: UUID
    var runId: UUID
    var ordinal: Int
    var tool: String
    var argumentsJson: String
    var spanCharStart: Int
    var spanCharEnd: Int
    var spanWordStart: Int?
    var spanWordEnd: Int?
    var spanStartMs: Int?
    var spanEndMs: Int?
    var confidence: Double
    var verdict: String
    var reviewReasons: String
    var reviewed: Bool
    var reviewedAt: Date?

    init(_ field: StructuredField) {
        id = field.id
        runId = field.runID
        ordinal = field.ordinal
        tool = field.tool
        argumentsJson = field.argumentsJSON
        spanCharStart = field.span.characterStart
        spanCharEnd = field.span.characterEnd
        spanWordStart = field.span.wordStart
        spanWordEnd = field.span.wordEnd
        spanStartMs = field.span.startMs
        spanEndMs = field.span.endMs
        confidence = field.confidence
        verdict = field.verdict.rawValue
        reviewReasons = (try? String(data: JSONEncoder().encode(field.reviewReasons), encoding: .utf8)) ?? "[]"
        reviewed = field.reviewed
        reviewedAt = nil
    }

    var field: StructuredField {
        StructuredField(
            id: id, runID: runId, tool: tool, argumentsJSON: argumentsJson,
            span: StructuredSourceSpan(
                characterStart: spanCharStart, characterEnd: spanCharEnd, wordStart: spanWordStart,
                wordEnd: spanWordEnd, startMs: spanStartMs, endMs: spanEndMs),
            confidence: confidence,
            // An unknown verdict (a newer build's value) reads as needs-review: never as act.
            verdict: StructuredVerdict(rawValue: verdict) ?? .needsReview,
            reviewReasons: (try? JSONDecoder().decode([String].self, from: Data(reviewReasons.utf8))) ?? [],
            reviewed: reviewed, ordinal: ordinal)
    }
}

struct StructuredEvalRunRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "structured_eval_runs"
    var id: UUID
    var engineId: String
    var modelSha256: String?
    var catalogVersion: String
    var caseCount: Int
    var toolShapeAccuracy: Double
    var argumentAccuracy: Double
    var numericHardFails: Int
    var reportJson: String
    var createdAt: Date

    init(_ run: StructuredEvalRun) {
        id = run.id
        engineId = run.engineID
        modelSha256 = run.modelSHA256
        catalogVersion = run.catalogVersion
        caseCount = run.caseCount
        toolShapeAccuracy = run.toolShapeAccuracy
        argumentAccuracy = run.argumentAccuracy
        numericHardFails = run.numericHardFails
        reportJson = run.reportJSON
        createdAt = run.createdAt
    }

    var run: StructuredEvalRun {
        StructuredEvalRun(
            id: id, engineID: engineId, modelSHA256: modelSha256, catalogVersion: catalogVersion,
            caseCount: caseCount, toolShapeAccuracy: toolShapeAccuracy, argumentAccuracy: argumentAccuracy,
            numericHardFails: numericHardFails, reportJSON: reportJson, createdAt: createdAt)
    }
}

/// GRDB-backed `StructuredResultStoring`. Logs carry ids and counts only, never field values.
public final class GRDBStructuredResultStore: StructuredResultStoring {
    private let database: DatabaseManager
    private static let logger = Log.logger("store")

    public init(database: DatabaseManager) {
        self.database = database
    }

    public func save(_ run: StructuredRun, fields: [StructuredField]) async throws {
        try await database.writer.write { db in
            try StructuredRunRecord(run).insert(db)
            for field in fields {
                try StructuredFieldRecord(field).insert(db)
            }
        }
        Self.logger.notice(
            "structured_run_saved run=\(run.id, privacy: .public) fields=\(fields.count, privacy: .public)")
    }

    public func runs(forTranscription id: UUID) async throws -> [StructuredRun] {
        try await database.writer.read { db in
            try StructuredRunRecord
                .filter(Column("transcriptionId") == id)
                .order(Column("createdAt").desc)
                .fetchAll(db)
                .map(\.run)
        }
    }

    public func fields(forRun id: UUID) async throws -> [StructuredField] {
        try await database.writer.read { db in
            try StructuredFieldRecord
                .filter(Column("runId") == id)
                .order(Column("ordinal"))
                .fetchAll(db)
                .map(\.field)
        }
    }

    public func setReviewed(fieldID: UUID, reviewed: Bool, argumentsJSON: String?) async throws {
        try await database.writer.write { db in
            guard var record = try StructuredFieldRecord.fetchOne(db, key: fieldID) else { return }
            record.reviewed = reviewed
            record.reviewedAt = reviewed ? Date() : nil
            if let argumentsJSON { record.argumentsJson = argumentsJSON }
            try record.update(db)
        }
    }

    public func saveEvalRun(_ run: StructuredEvalRun) async throws {
        try await database.writer.write { db in try StructuredEvalRunRecord(run).insert(db) }
    }

    public func evalRuns() async throws -> [StructuredEvalRun] {
        try await database.writer.read { db in
            try StructuredEvalRunRecord.order(Column("createdAt").desc).fetchAll(db).map(\.run)
        }
    }
}
