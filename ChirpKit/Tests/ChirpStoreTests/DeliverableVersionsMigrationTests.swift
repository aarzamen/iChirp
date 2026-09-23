import ChirpCore
import GRDB
import XCTest

@testable import ChirpStore

/// Plan 022 review M8: `v8-text-items` applied to a database from before it (`v7-structured-results`, as an iPhone
/// that ran the previous build has it). Every existing row is unchanged, the append-only versions table and its
/// triggers exist, and a document made before the upgrade gets its first version. Every text is synthetic.
final class DeliverableVersionsMigrationTests: XCTestCase {
    private let transcriptID = UUID()
    private let deliverableID = UUID()
    private let runID = UUID()
    private let created = Date(timeIntervalSinceReferenceDate: 780_000_000)
    private static let summary = "Synthetic summary written before the upgrade."

    /// A v7 database with a clinical transcription, a Summary made from it and its ledger row.
    private func makeV7Database() throws -> DatabaseQueue {
        var config = Configuration()
        config.foreignKeysEnabled = true
        let queue = try DatabaseQueue(configuration: config)
        try DatabaseManager.migrator.migrate(queue, upTo: "v7-structured-results")
        try queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO transcriptions
                        (id, createdAt, updatedAt, sourceType, fileName, status, rawTranscript, isFavorite,
                         privacyClass)
                    VALUES (?, ?, ?, 'file', 'Synthetic visit.m4a', 'completed', 'Synthetic visit text.', 1,
                            'clinical')
                    """,
                arguments: [transcriptID, created, created])
            try db.execute(
                sql: """
                    INSERT INTO deliverables
                        (id, transcriptionId, promptId, promptVersionId, title, engineId, provider, model, locality,
                         text, privacyClass, userNotes, createdAt, updatedAt, editedAt)
                    VALUES (?, ?, NULL, NULL, 'Summary', 'fake.engine', 'Fake', 'fake-1', 'onDevice', ?,
                            'clinical', NULL, ?, ?, NULL)
                    """,
                arguments: [deliverableID, transcriptID, Self.summary, created, created])
            try db.execute(
                sql: """
                    INSERT INTO llm_runs
                        (id, feature, status, transcriptionId, deliverableId, promptVersionId, engineId, provider,
                         model, locality, privacyClass, privacyOverride, inputCharacters, outputCharacters,
                         callCount, createdAt)
                    VALUES (?, 'deliverable', 'succeeded', ?, ?, NULL, 'fake.engine', 'Fake', 'fake-1', 'onDevice',
                            'clinical', 0, 21, 44, 1, ?)
                    """,
                arguments: [runID, transcriptID, deliverableID, created])
        }
        return queue
    }

    /// Every row of the tables that existed before, exactly as stored.
    private func snapshot(_ queue: DatabaseQueue) throws -> [String: [Row]] {
        try queue.read { db in
            var tables: [String: [Row]] = [:]
            for table in ["transcriptions", "deliverables", "llm_runs", "prompts", "prompt_versions"] {
                tables[table] = try Row.fetchAll(db, sql: "SELECT * FROM \(table) ORDER BY id")
            }
            return tables
        }
    }

    func testTheUpgradeKeepsEveryRowAndAddsTheVersionsTable() throws {
        let queue = try makeV7Database()
        XCTAssertFalse(try queue.read { db in try db.tableExists("deliverable_versions") })
        let before = try snapshot(queue)
        XCTAssertEqual(before["transcriptions"]?.count, 1)
        XCTAssertEqual(before["deliverables"]?.count, 1)
        XCTAssertEqual(before["llm_runs"]?.count, 1)

        _ = try DatabaseManager(writer: queue)

        XCTAssertEqual(try snapshot(queue), before, "no existing row changes")
        let applied = try queue.read { db in try DatabaseManager.migrator.appliedIdentifiers(db) }
        XCTAssertTrue(applied.contains("v8-text-items"), "\(applied)")
        XCTAssertTrue(try queue.read { db in try db.tableExists("deliverable_versions") })
        let triggers = try queue.read { db in
            try String.fetchAll(
                db, sql: "SELECT name FROM sqlite_master WHERE type = 'trigger' AND tbl_name = 'deliverable_versions'")
        }
        XCTAssertEqual(
            Set(triggers), ["deliverable_versions_immutable_update", "deliverable_versions_immutable_delete"])
        let versions = try queue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM deliverable_versions") }
        XCTAssertEqual(versions, 0, "the upgrade adds no version")
    }

    func testAnOldDocumentReadsAsBeforeAndTakesItsFirstVersion() async throws {
        let queue = try makeV7Database()
        let database = try DatabaseManager(writer: queue)
        let transcripts = GRDBTranscriptionStore(database: database)
        let store = GRDBDeliverableStore(database: database)

        let transcript = try await transcripts.fetch(id: transcriptID)
        XCTAssertEqual(transcript?.privacyClass, .clinical)
        XCTAssertEqual(transcript?.rawTranscript, "Synthetic visit text.")
        XCTAssertEqual(transcript?.isFavorite, true)
        let document = try await store.fetchDeliverable(id: deliverableID)
        XCTAssertEqual(document?.text, Self.summary)
        XCTAssertEqual(document?.privacyClass, .clinical)
        XCTAssertNil(document?.editedAt)
        let runs = try await store.fetchRuns(limit: 10)
        XCTAssertEqual(runs.map(\.id), [runID])
        XCTAssertEqual(runs.first?.deliverableID, deliverableID)
        let none = try await store.fetchDeliverableVersions(deliverableID: deliverableID)
        XCTAssertTrue(none.isEmpty)

        let result = try await store.appendDeliverableVersion(
            DeliverableVersionDraft(
                text: "Synthetic summary, shorter.", origin: .spokenEdit, instruction: "Make it shorter",
                engineID: "fake.engine", provider: "Fake", model: "fake-1", locality: .onDevice,
                privacyClass: .personal, createdAt: created.addingTimeInterval(60)),
            deliverableID: deliverableID)
        let appended = try XCTUnwrap(result)
        XCTAssertEqual(appended.versions.map(\.origin), [.original, .spokenEdit])
        XCTAssertEqual(appended.versions.first?.text, Self.summary, "the text from before the upgrade is version 1")
        XCTAssertEqual(appended.deliverable.privacyClass, .clinical, "never lowered")
        let ledger = try await store.fetchRuns(limit: 10)
        XCTAssertEqual(ledger.map(\.id), [runID], "the old ledger row is untouched")
    }
}
