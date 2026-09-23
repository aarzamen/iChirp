import Foundation

// M6 (plan 015): the evidence ledger of structure-model results. Contract: spec/contracts/structured-results-v1.md.
// Stored in the local database only (tables from migration "v7-structured-results"); logs carry ids and counts only.

/// What the confidence gate decided for one field.
public enum StructuredVerdict: String, Codable, Sendable, CaseIterable {
    /// At or above the act threshold (default 0.85) and every check passed: shown solid, still a draft until reviewed.
    case act
    /// At or above the provisional threshold (default 0.60): shown dashed.
    case provisional
    /// Below provisional, or a check failed (a number that does not trace to the transcript, out of range, a spoken
    /// self-correction, a schema problem): kept out of the draft, in the "Needs review" bin.
    case needsReview
}

/// One extraction run over one item: which catalog, which engine and model file, when.
public struct StructuredRun: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    /// The transcript the run read.
    public var transcriptionID: UUID
    /// e.g. "soap-meds.v1".
    public var catalogVersion: String
    /// e.g. "needle.needle3" or "stub.rules".
    public var engineID: String
    /// SHA-256 of the model file; nil for the STUB.
    public var modelSHA256: String?
    public var actThreshold: Double
    public var provisionalThreshold: Double
    public var createdAt: Date

    public init(
        id: UUID = UUID(), transcriptionID: UUID, catalogVersion: String, engineID: String, modelSHA256: String?,
        actThreshold: Double, provisionalThreshold: Double, createdAt: Date = Date()
    ) {
        self.id = id
        self.transcriptionID = transcriptionID
        self.catalogVersion = catalogVersion
        self.engineID = engineID
        self.modelSHA256 = modelSHA256
        self.actThreshold = actThreshold
        self.provisionalThreshold = provisionalThreshold
        self.createdAt = createdAt
    }
}

/// Where a field came from in the transcript.
public struct StructuredSourceSpan: Codable, Sendable, Equatable, Hashable {
    /// UTF-16 offsets into the run's source text (the transcript's words joined by spaces, or its text).
    public var characterStart: Int
    public var characterEnd: Int
    /// Half-open range into `Transcription.wordTimestamps`, when the transcript has words.
    public var wordStart: Int?
    public var wordEnd: Int?
    /// Audio time of those words, for "tap the field → the player seeks".
    public var startMs: Int?
    public var endMs: Int?

    public init(
        characterStart: Int, characterEnd: Int, wordStart: Int? = nil, wordEnd: Int? = nil, startMs: Int? = nil,
        endMs: Int? = nil
    ) {
        self.characterStart = characterStart
        self.characterEnd = characterEnd
        self.wordStart = wordStart
        self.wordEnd = wordEnd
        self.startMs = startMs
        self.endMs = endMs
    }
}

/// One applied (or held-back) field of a run: the validated tool call, its evidence and the gate's verdict.
public struct StructuredField: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var runID: UUID
    /// The tool that produced it, e.g. "add_medication".
    public var tool: String
    /// The call's arguments after tag mapping (JSON object; numbers as the normalizer parsed them).
    public var argumentsJSON: String
    public var span: StructuredSourceSpan
    public var confidence: Double
    public var verdict: StructuredVerdict
    /// Why the gate forced review, in words (empty when none).
    public var reviewReasons: [String]
    /// The person confirmed or edited it. Nothing is final before this.
    public var reviewed: Bool
    /// Order within the run.
    public var ordinal: Int

    public init(
        id: UUID = UUID(), runID: UUID, tool: String, argumentsJSON: String, span: StructuredSourceSpan,
        confidence: Double, verdict: StructuredVerdict, reviewReasons: [String] = [], reviewed: Bool = false,
        ordinal: Int
    ) {
        self.id = id
        self.runID = runID
        self.tool = tool
        self.argumentsJSON = argumentsJSON
        self.span = span
        self.confidence = confidence
        self.verdict = verdict
        self.reviewReasons = reviewReasons
        self.reviewed = reviewed
        self.ordinal = ordinal
    }
}

/// A saved Eval run (synthetic cases only): the three headline numbers and the full JSON report.
public struct StructuredEvalRun: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var engineID: String
    public var modelSHA256: String?
    /// e.g. "soap-meds.v1+dictation-commands.v1".
    public var catalogVersion: String
    public var caseCount: Int
    public var toolShapeAccuracy: Double
    public var argumentAccuracy: Double
    public var numericHardFails: Int
    /// The exported report (synthetic content only).
    public var reportJSON: String
    public var createdAt: Date

    public init(
        id: UUID = UUID(), engineID: String, modelSHA256: String?, catalogVersion: String, caseCount: Int,
        toolShapeAccuracy: Double, argumentAccuracy: Double, numericHardFails: Int, reportJSON: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.engineID = engineID
        self.modelSHA256 = modelSHA256
        self.catalogVersion = catalogVersion
        self.caseCount = caseCount
        self.toolShapeAccuracy = toolShapeAccuracy
        self.argumentAccuracy = argumentAccuracy
        self.numericHardFails = numericHardFails
        self.reportJSON = reportJSON
        self.createdAt = createdAt
    }
}

/// The evidence ledger's storage. `GRDBStructuredResultStore` in the app; an in-memory fake in tests.
public protocol StructuredResultStoring: Sendable {
    /// Saves a run and its fields in one transaction.
    func save(_ run: StructuredRun, fields: [StructuredField]) async throws
    /// Runs for a transcript, newest first.
    func runs(forTranscription id: UUID) async throws -> [StructuredRun]
    /// A run's fields in order.
    func fields(forRun id: UUID) async throws -> [StructuredField]
    /// The person reviewed (or un-reviewed) a field, optionally with edited arguments.
    func setReviewed(fieldID: UUID, reviewed: Bool, argumentsJSON: String?) async throws
    func saveEvalRun(_ run: StructuredEvalRun) async throws
    func evalRuns() async throws -> [StructuredEvalRun]
}
