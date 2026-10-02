import ChirpCore
import GRDB
import XCTest

@testable import ChirpStore

/// Plan 026: `v12-template-library` adds `prompts.isVisible` (NOT NULL, default 1) to a database from before it, as an
/// iPhone that ran the previous build has it. Every pre-existing column of every row stays as stored, every template
/// reads as shown, and template versions stay immutable. Every text is synthetic.
final class TemplateLibraryMigrationTests: XCTestCase {
    private let transcriptID = UUID()
    private let summaryID = UUID()
    private let soapID = UUID()
    private let mineID = UUID()
    private let mineV1 = UUID()
    private let mineV2 = UUID()
    private let deliverableID = UUID()
    private let created = Date(timeIntervalSinceReferenceDate: 780_000_000)

    /// The column lists of the tables as they were before this migration (selected explicitly, so a later additive
    /// migration cannot hide a change to one of them).
    private static let oldColumns: [String: String] = [
        "transcriptions":
            "id, createdAt, updatedAt, sourceType, fileName, status, rawTranscript, isFavorite, privacyClass",
        "prompts": """
        id, name, category, isBuiltIn, canonicalKey, canonicalRevision, outputPrivacyClass, sortOrder, \
        activeVersionId, userCustomizedAt, deletedAt, createdAt, updatedAt
        """,
        "prompt_versions": "id, promptId, versionNumber, content, origin, createdAt",
        "deliverables": """
        id, transcriptionId, promptId, promptVersionId, title, engineId, provider, model, locality, text, \
        privacyClass, userNotes, createdAt, updatedAt, editedAt, isCutOff
        """,
        "llm_runs": """
        id, feature, status, transcriptionId, deliverableId, promptVersionId, engineId, provider, model, locality, \
        privacyClass, privacyOverride, errorType, promptTokens, completionTokens, latencyMs, inputCharacters, \
        outputCharacters, callCount, createdAt
        """,
        "deliverable_versions": """
        id, deliverableId, versionNumber, text, origin, instruction, restoredFrom, engineId, provider, model, \
        locality, privacyClass, createdAt, isCutOff
        """,
    ]

    /// A database migrated up to `v10-deliverable-cut-off` (the last migration on `main` before this one; plan 025's
    /// parallel v11 then runs too) holding two built-ins in a person's order (SOAP note before Summary), one user
    /// template with two versions, a document naming version 1, its version and a ledger row.
    private func makeOldDatabase() throws -> DatabaseQueue {
        var config = Configuration()
        config.foreignKeysEnabled = true
        let queue = try DatabaseQueue(configuration: config)
        try DatabaseManager.migrator.migrate(queue, upTo: "v10-deliverable-cut-off")
        try queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO transcriptions
                        (id, createdAt, updatedAt, sourceType, fileName, status, rawTranscript, isFavorite,
                         privacyClass)
                    VALUES (?, ?, ?, 'file', 'Synthetic visit.m4a', 'completed', 'Synthetic visit text.', 0,
                            'clinical')
                    """,
                arguments: [transcriptID, created, created])
            let builtIns: [(UUID, String, String, String, Int, String?)] = [
                (summaryID, "summary", "Summary", "Summarize.", 7, nil),
                (soapID, "soap-note", "SOAP note", "Write a SOAP note.", 4, "clinical"),
            ]
            for (id, key, name, content, order, output) in builtIns {
                let versionID = UUID()
                try db.execute(
                    sql: """
                        INSERT INTO prompts
                            (id, name, category, isBuiltIn, canonicalKey, canonicalRevision, outputPrivacyClass,
                             sortOrder, activeVersionId, userCustomizedAt, deletedAt, createdAt, updatedAt)
                        VALUES (?, ?, 'deliverable', 1, ?, 1, ?, ?, ?, NULL, NULL, ?, ?)
                        """,
                    arguments: [id, name, key, output, order, versionID, created, created])
                try db.execute(
                    sql: """
                        INSERT INTO prompt_versions (id, promptId, versionNumber, content, origin, createdAt)
                        VALUES (?, ?, 1, ?, 'builtIn', ?)
                        """,
                    arguments: [versionID, id, content, created])
            }
            try db.execute(
                sql: """
                    INSERT INTO prompts
                        (id, name, category, isBuiltIn, canonicalKey, canonicalRevision, outputPrivacyClass,
                         sortOrder, activeVersionId, userCustomizedAt, deletedAt, createdAt, updatedAt)
                    VALUES (?, 'Clinic SOAP', 'deliverable', 0, NULL, NULL, 'clinical', 9, ?, NULL, NULL, ?, ?)
                    """,
                arguments: [mineID, mineV2, created, created])
            for (id, number, content) in [(mineV1, 1, "Headings A."), (mineV2, 2, "Headings B.")] {
                try db.execute(
                    sql: """
                        INSERT INTO prompt_versions (id, promptId, versionNumber, content, origin, createdAt)
                        VALUES (?, ?, ?, ?, 'user', ?)
                        """,
                    arguments: [id, mineID, number, content, created])
            }
            try db.execute(
                sql: """
                    INSERT INTO deliverables
                        (id, transcriptionId, promptId, promptVersionId, title, engineId, provider, model, locality,
                         text, privacyClass, userNotes, createdAt, updatedAt, editedAt, isCutOff)
                    VALUES (?, ?, ?, ?, 'Clinic SOAP', 'fake.engine', 'Fake', 'fake-1', 'onDevice',
                            'Synthetic note.', 'clinical', 'Synthetic notes.', ?, ?, NULL, 0)
                    """,
                arguments: [deliverableID, transcriptID, mineID, mineV1, created, created])
            try db.execute(
                sql: """
                    INSERT INTO deliverable_versions
                        (id, deliverableId, versionNumber, text, origin, privacyClass, createdAt, isCutOff)
                    VALUES (?, ?, 1, 'Synthetic note.', 'original', 'clinical', ?, 0)
                    """,
                arguments: [UUID(), deliverableID, created])
            try db.execute(
                sql: """
                    INSERT INTO llm_runs
                        (id, feature, status, transcriptionId, deliverableId, promptVersionId, engineId, provider,
                         model, locality, privacyClass, privacyOverride, inputCharacters, outputCharacters,
                         callCount, createdAt)
                    VALUES (?, 'deliverable', 'succeeded', ?, ?, ?, 'fake.engine', 'Fake', 'fake-1', 'onDevice',
                            'clinical', 0, 21, 15, 1, ?)
                    """,
                arguments: [UUID(), transcriptID, deliverableID, mineV1, created])
        }
        return queue
    }

    private func snapshot(_ queue: DatabaseQueue) throws -> [String: [Row]] {
        try queue.read { db in
            var tables: [String: [Row]] = [:]
            for (table, columns) in Self.oldColumns {
                tables[table] = try Row.fetchAll(db, sql: "SELECT \(columns) FROM \(table) ORDER BY id")
            }
            return tables
        }
    }

    func testANewDatabaseHasTheColumn() throws {
        let database = try DatabaseManager.inMemory()
        let (applied, columns) = try database.writer.read { db in
            (try DatabaseManager.migrator.appliedIdentifiers(db), try db.columns(in: "prompts"))
        }
        XCTAssertTrue(applied.contains("v12-template-library"), "\(applied)")
        let column = try XCTUnwrap(columns.first { $0.name == "isVisible" })
        XCTAssertTrue(column.isNotNull)
        XCTAssertEqual(column.defaultValueSQL, "1")
    }

    func testTheUpgradeKeepsEveryRowAndShowsEveryTemplate() async throws {
        let queue = try makeOldDatabase()
        let oldNames = try await queue.read { db in try db.columns(in: "prompts").map(\.name) }
        XCTAssertFalse(oldNames.contains("isVisible"))
        let before = try snapshot(queue)
        XCTAssertEqual(before.values.map(\.count).reduce(0, +), 1 + 3 + 4 + 1 + 1 + 1)

        let store = GRDBDeliverableStore(database: try DatabaseManager(writer: queue))

        let after = try snapshot(queue)
        for table in Self.oldColumns.keys {
            XCTAssertEqual(after[table], before[table], "\(table): no pre-existing value changes")
        }
        let visible = try await queue.read { db in try Int.fetchAll(db, sql: "SELECT isVisible FROM prompts") }
        XCTAssertEqual(visible, [1, 1, 1])
        let column = try await queue.read { db in try db.columns(in: "prompts").first { $0.name == "isVisible" } }
        XCTAssertEqual(column?.isNotNull, true)
        XCTAssertEqual(column?.defaultValueSQL, "1")

        let templates = try await store.fetchTemplates()
        XCTAssertEqual(templates.map(\.id), [soapID, summaryID, mineID], "the stored order is kept")
        XCTAssertTrue(templates.allSatisfy(\.isVisible))
        let document = try await store.fetchDeliverable(id: deliverableID)
        XCTAssertEqual(document?.promptVersionID, mineV1)
        let value1 = try await store.fetchVersion(id: mineV1)?.content
        XCTAssertEqual(value1, "Headings A.")
    }

    func testTemplateVersionsStayImmutableAfterTheUpgrade() throws {
        let queue = try makeOldDatabase()
        _ = try DatabaseManager(writer: queue)
        XCTAssertThrowsError(
            try queue.write { db in
                try db.execute(
                    sql: "UPDATE prompt_versions SET content = 'Changed.' WHERE promptId = ?", arguments: [mineID])
            })
        XCTAssertThrowsError(
            try queue.write { db in
                try db.execute(sql: "DELETE FROM prompt_versions WHERE promptId = ?", arguments: [mineID])
            })
        let contents = try queue.read { db in
            try String.fetchAll(
                db, sql: "SELECT content FROM prompt_versions WHERE promptId = ? ORDER BY versionNumber",
                arguments: [mineID])
        }
        XCTAssertEqual(contents, ["Headings A.", "Headings B."])
    }
}
