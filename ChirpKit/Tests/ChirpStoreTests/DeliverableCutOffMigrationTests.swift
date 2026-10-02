import ChirpCore
import GRDB
import XCTest

@testable import ChirpStore

/// Plan 024 Task 8 (reviews R3-1, R4-2): `v10-deliverable-cut-off` adds `isCutOff` to `deliverables` and
/// `deliverable_versions`, false for every existing row. A document the model stopped writing at its length limit keeps
/// its mark across a relaunch, through hand edits, and follows a restored version. Every text is synthetic.
final class DeliverableCutOffMigrationTests: XCTestCase {
    private let transcriptID = UUID()
    private let deliverableID = UUID()
    private let created = Date(timeIntervalSinceReferenceDate: 780_000_000)

    /// A v9 database (the build before this one) with a transcription, a Summary and one version of it.
    private func makeV9Database() throws -> DatabaseQueue {
        var config = Configuration()
        config.foreignKeysEnabled = true
        let queue = try DatabaseQueue(configuration: config)
        try DatabaseManager.migrator.migrate(queue, upTo: "v9-llm-runs-deliverable-index")
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
                    INSERT INTO deliverable_versions
                        (id, deliverableId, versionNumber, text, origin, privacyClass, createdAt)
                    VALUES (?, ?, 1, 'Synthetic summary.', 'original', 'personal', ?)
                    """,
                arguments: [UUID(), deliverableID, created])
        }
        return queue
    }

    private func columns(_ queue: DatabaseQueue, _ table: String) throws -> [String] {
        try queue.read { db in try db.columns(in: table).map(\.name) }
    }

    func testANewDatabaseHasTheColumns() throws {
        let database = try DatabaseManager.inMemory()
        let applied = try database.writer.read { db in try DatabaseManager.migrator.appliedIdentifiers(db) }
        XCTAssertTrue(applied.contains("v10-deliverable-cut-off"), "\(applied)")
        for table in ["deliverables", "deliverable_versions"] {
            let names = try database.writer.read { db in try db.columns(in: table).map(\.name) }
            XCTAssertTrue(names.contains("isCutOff"), table)
        }
    }

    func testTheUpgradeAddsTheColumnsFalseAndKeepsEveryRow() async throws {
        let queue = try makeV9Database()
        XCTAssertFalse(try columns(queue, "deliverables").contains("isCutOff"))
        let before = try queue.read { db in
            try Row.fetchAll(db, sql: "SELECT text, privacyClass, title FROM deliverables")
        }

        let store = GRDBDeliverableStore(database: try DatabaseManager(writer: queue))

        let after = try queue.read { db in
            try Row.fetchAll(db, sql: "SELECT text, privacyClass, title FROM deliverables")
        }
        XCTAssertEqual(after, before, "no existing value changes")
        let document = try await store.fetchDeliverable(id: deliverableID)
        XCTAssertEqual(document?.isCutOff, false)
        let versions = try await store.fetchDeliverableVersions(deliverableID: deliverableID)
        XCTAssertEqual(versions.map(\.isCutOff), [false])
    }

    /// The mark survives a relaunch (a new `DatabaseManager` on the same file) and a hand edit; a restore takes the
    /// restored version's mark.
    func testTheMarkSurvivesARelaunchAHandEditAndFollowsARestore() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
            "CutOff-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("ichirp.sqlite")

        var row = Transcription(sourceType: .text, fileName: "Text", status: .completed)
        row.rawTranscript = "Synthetic source."
        do {
            let database = try DatabaseManager(url: url)
            try await GRDBTranscriptionStore(database: database).insert(row)
            let store = GRDBDeliverableStore(database: database)
            try await store.insertDeliverable(
                Deliverable(
                    id: deliverableID, transcriptionID: row.id, promptID: nil, promptVersionID: nil, title: "Summary",
                    engineID: "fake.engine", provider: "Fake", model: "fake-1", locality: .onDevice,
                    text: "A summary that stops", privacyClass: .personal, isCutOff: true))
        }

        let database = try DatabaseManager(url: url)
        let store = GRDBDeliverableStore(database: database)
        let reopened = try await store.fetchDeliverable(id: deliverableID)
        XCTAssertEqual(reopened?.isCutOff, true, "the mark is stored, not held in memory")
        let edited = try await store.updateDeliverableText(id: deliverableID, text: "A summary that stops, edited")
        XCTAssertEqual(edited?.isCutOff, true, "a hand edit keeps the mark")

        let whole = try await store.appendDeliverableVersion(
            DeliverableVersionDraft(text: "A whole summary.", origin: .typedEdit, privacyClass: .personal),
            deliverableID: deliverableID)
        XCTAssertEqual(whole?.deliverable.isCutOff, false)
        XCTAssertEqual(whole?.versions.map(\.isCutOff), [true, false], "the kept hand edit keeps its mark")

        let restored = try await store.appendDeliverableVersion(
            DeliverableVersionDraft(
                text: "A summary that stops, edited", origin: .restore, restoredFrom: 1,
                privacyClass: .personal),
            deliverableID: deliverableID)
        XCTAssertEqual(restored?.deliverable.isCutOff, true, "a restore takes the restored version's mark")
        XCTAssertEqual(restored?.versions.last?.isCutOff, true)
    }
}
