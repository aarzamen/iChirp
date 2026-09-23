import ChirpCore
import GRDB
import XCTest

@testable import ChirpStore

/// Step 5 (plan 015): migration `v7-structured-results` and the evidence-ledger store.
final class StructuredResultsMigrationTests: XCTestCase {
    func testMigrationCreatesTheThreeTables() throws {
        let database = try DatabaseManager.inMemory()
        let applied = try database.writer.read { db in try DatabaseManager.migrator.appliedIdentifiers(db) }
        XCTAssertTrue(applied.contains("v7-structured-results"), "\(applied)")
        let tables = ["structured_runs", "structured_fields", "structured_eval_runs"]
        for table in tables {
            XCTAssertTrue(try database.writer.read { db in try db.tableExists(table) }, table)
        }
        let fieldColumns = try database.writer.read { db in try db.columns(in: "structured_fields").map(\.name) }
        for name in [
            "runId", "tool", "argumentsJson", "spanCharStart", "spanCharEnd", "spanWordStart", "spanWordEnd",
            "spanStartMs", "spanEndMs", "confidence", "verdict", "reviewed",
        ] {
            XCTAssertTrue(fieldColumns.contains(name), name)
        }
        let runColumns = try database.writer.read { db in try db.columns(in: "structured_runs").map(\.name) }
        for name in ["transcriptionId", "catalogVersion", "engineId", "modelSha256", "createdAt"] {
            XCTAssertTrue(runColumns.contains(name), name)
        }
    }

    func testMigrationRunsOnADatabaseFromBeforeIt() throws {
        let queue = try DatabaseQueue()
        try DatabaseManager.migrator.migrate(queue, upTo: "v6-documents")
        try DatabaseManager.migrator.migrate(queue)
        XCTAssertTrue(try queue.read { db in try db.tableExists("structured_runs") })
    }

    private func makeStore() async throws -> (GRDBStructuredResultStore, GRDBTranscriptionStore, UUID) {
        let database = try DatabaseManager.inMemory()
        let transcripts = GRDBTranscriptionStore(database: database)
        let id = UUID()
        try await transcripts.insert(
            Transcription(id: id, sourceType: .dictation, fileName: "Synthetic.wav", status: .completed))
        return (GRDBStructuredResultStore(database: database), transcripts, id)
    }

    func testRunAndFieldsRoundTripWithEvidenceAndReview() async throws {
        let (store, _, transcriptID) = try await makeStore()
        let run = StructuredRun(
            transcriptionID: transcriptID, catalogVersion: "soap-meds.v1", engineID: "needle.needle3",
            modelSHA256: "c9d915ec", actThreshold: 0.85, provisionalThreshold: 0.6)
        let field = StructuredField(
            runID: run.id, tool: "record_vital", argumentsJSON: #"{"kind":"BP"}"#,
            span: StructuredSourceSpan(
                characterStart: 3, characterEnd: 9, wordStart: 1, wordEnd: 2, startMs: 500, endMs: 900),
            confidence: 0.91, verdict: .act, reviewReasons: [], ordinal: 0)
        let held = StructuredField(
            runID: run.id, tool: "add_medication", argumentsJSON: #"{"drug":"x"}"#,
            span: StructuredSourceSpan(characterStart: 10, characterEnd: 20), confidence: 0.4, verdict: .needsReview,
            reviewReasons: ["“x” is not in this sentence."], ordinal: 1)
        try await store.save(run, fields: [held, field].sorted { $0.ordinal < $1.ordinal })

        let runs = try await store.runs(forTranscription: transcriptID)
        XCTAssertEqual(runs.map(\.id), [run.id])
        XCTAssertEqual(runs.first?.modelSHA256, "c9d915ec")
        let fields = try await store.fields(forRun: run.id)
        XCTAssertEqual(fields, [field, held])
        XCTAssertFalse(fields[0].reviewed, "nothing is reviewed until the person says so")

        try await store.setReviewed(fieldID: field.id, reviewed: true, argumentsJSON: #"{"kind":"BP","edited":true}"#)
        let reviewed = try await store.fields(forRun: run.id)[0]
        XCTAssertTrue(reviewed.reviewed)
        XCTAssertEqual(reviewed.argumentsJSON, #"{"kind":"BP","edited":true}"#)
    }

    func testDeletingTheTranscriptDeletesItsRuns() async throws {
        let (store, transcripts, transcriptID) = try await makeStore()
        let run = StructuredRun(
            transcriptionID: transcriptID, catalogVersion: "soap-meds.v1", engineID: "stub.rules", modelSHA256: nil,
            actThreshold: 0.85, provisionalThreshold: 0.6)
        try await store.save(
            run,
            fields: [
                StructuredField(
                    runID: run.id, tool: "none", argumentsJSON: "{}",
                    span: StructuredSourceSpan(characterStart: 0, characterEnd: 1),
                    confidence: 0.6, verdict: .provisional, ordinal: 0)
            ])
        try await transcripts.delete(id: transcriptID)
        let runs = try await store.runs(forTranscription: transcriptID)
        XCTAssertEqual(runs, [])
        let fields = try await store.fields(forRun: run.id)
        XCTAssertEqual(fields, [])
    }

    func testEvalRunsRoundTrip() async throws {
        let (store, _, _) = try await makeStore()
        let eval = StructuredEvalRun(
            engineID: "stub.rules", modelSHA256: nil, catalogVersion: "soap-meds.v1+dictation-commands.v1",
            caseCount: 38, toolShapeAccuracy: 0.9, argumentAccuracy: 0.8, numericHardFails: 0, reportJSON: "{}")
        try await store.saveEvalRun(eval)
        let runs = try await store.evalRuns()
        XCTAssertEqual(runs.map(\.id), [eval.id])
        XCTAssertEqual(runs.first?.caseCount, 38)
    }
}
