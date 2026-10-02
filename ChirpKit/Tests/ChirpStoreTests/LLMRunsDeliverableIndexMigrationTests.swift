import ChirpCore
import GRDB
import XCTest

@testable import ChirpStore

/// Review R1-17: `v9-llm-runs-deliverable-index` indexes `llm_runs.deliverableId`, so deleting a document (alone or
/// with its transcript) no longer scans the whole run ledger to null the reference. Applied to a database from before
/// it (`v8-text-items`, as an iPhone that ran the previous build has it): an index only, every row unchanged. Every
/// text is synthetic.
final class LLMRunsDeliverableIndexMigrationTests: XCTestCase {
    private static let index = "idx_llm_runs_deliverable_id"
    private let transcriptID = UUID()
    private let deliverableID = UUID()
    private let runID = UUID()
    private let created = Date(timeIntervalSinceReferenceDate: 780_000_000)

    /// A v8 database with a transcription, a Summary made from it and its ledger row.
    private func makeV8Database() throws -> DatabaseQueue {
        var config = Configuration()
        config.foreignKeysEnabled = true
        let queue = try DatabaseQueue(configuration: config)
        try DatabaseManager.migrator.migrate(queue, upTo: "v8-text-items")
        try queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO transcriptions
                        (id, createdAt, updatedAt, sourceType, fileName, status, rawTranscript, isFavorite,
                         privacyClass)
                    VALUES (?, ?, ?, 'file', 'Synthetic visit.m4a', 'completed', 'Synthetic visit text.', 0,
                            'personal')
                    """,
                arguments: [transcriptID, created, created])
            try db.execute(
                sql: """
                    INSERT INTO deliverables
                        (id, transcriptionId, promptId, promptVersionId, title, engineId, provider, model, locality,
                         text, privacyClass, userNotes, createdAt, updatedAt, editedAt)
                    VALUES (?, ?, NULL, NULL, 'Summary', 'fake.engine', 'Fake', 'fake-1', 'onDevice',
                            'Synthetic summary.', 'personal', NULL, ?, ?, NULL)
                    """,
                arguments: [deliverableID, transcriptID, created, created])
            try db.execute(
                sql: """
                    INSERT INTO llm_runs
                        (id, feature, status, transcriptionId, deliverableId, promptVersionId, engineId, provider,
                         model, locality, privacyClass, privacyOverride, inputCharacters, outputCharacters,
                         callCount, createdAt)
                    VALUES (?, 'deliverable', 'succeeded', ?, ?, NULL, 'fake.engine', 'Fake', 'fake-1', 'onDevice',
                            'personal', 0, 21, 18, 1, ?)
                    """,
                arguments: [runID, transcriptID, deliverableID, created])
        }
        return queue
    }

    private func snapshot(_ queue: DatabaseQueue) throws -> [String: [Row]] {
        try queue.read { db in
            var tables: [String: [Row]] = [:]
            for table in ["transcriptions", "deliverables", "llm_runs", "deliverable_versions"] {
                tables[table] = try Row.fetchAll(db, sql: "SELECT * FROM \(table) ORDER BY id")
            }
            return tables
        }
    }

    private func deliverableIndexColumns(_ db: Database) throws -> [String]? {
        try db.indexes(on: "llm_runs").first { $0.name == Self.index }?.columns
    }

    func testANewDatabaseHasTheIndex() throws {
        let database = try DatabaseManager.inMemory()
        let columns = try database.writer.read { db in try deliverableIndexColumns(db) }
        XCTAssertEqual(columns, ["deliverableId"])
        let applied = try database.writer.read { db in try DatabaseManager.migrator.appliedIdentifiers(db) }
        XCTAssertTrue(applied.contains("v9-llm-runs-deliverable-index"), "\(applied)")
    }

    func testTheUpgradeAddsOnlyTheIndexAndKeepsEveryRow() throws {
        let queue = try makeV8Database()
        XCTAssertNil(try queue.read { db in try deliverableIndexColumns(db) })
        let before = try snapshot(queue)

        // Up to this migration only: a later additive column (v10's `isCutOff`) is that migration's own test.
        try DatabaseManager.migrator.migrate(queue, upTo: "v9-llm-runs-deliverable-index")

        XCTAssertEqual(try snapshot(queue), before, "no existing row changes")
        XCTAssertEqual(try queue.read { db in try deliverableIndexColumns(db) }, ["deliverableId"])
        let plan = try queue.read { db in
            try Row.fetchAll(
                db, sql: "EXPLAIN QUERY PLAN SELECT id FROM llm_runs WHERE deliverableId = ?",
                arguments: [deliverableID]
            ).map { "\($0)" }.joined(separator: " ")
        }
        XCTAssertTrue(plan.contains(Self.index), "a document's ledger rows are found through the index: \(plan)")
    }

    func testDeletingADocumentStillKeepsItsLedgerRowWithoutTheReference() async throws {
        let queue = try makeV8Database()
        let store = GRDBDeliverableStore(database: try DatabaseManager(writer: queue))

        try await store.deleteDeliverable(id: deliverableID)

        let runs = try await store.fetchRuns(limit: 10)
        XCTAssertEqual(runs.map(\.id), [runID], "the ledger outlives the document")
        XCTAssertNil(runs.first?.deliverableID, "ON DELETE SET NULL, as before")
        XCTAssertEqual(runs.first?.transcriptionID, transcriptID)
    }
}
