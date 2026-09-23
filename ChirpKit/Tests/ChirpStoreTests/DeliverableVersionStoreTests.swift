import ChirpCore
import GRDB
import XCTest

@testable import ChirpStore

/// Plan 022 Step 4: `v8-text-items` and the append-only document versions. Every text is synthetic.
final class DeliverableVersionStoreTests: XCTestCase {
    private var database: DatabaseManager!
    private var transcripts: GRDBTranscriptionStore!
    private var store: GRDBDeliverableStore!
    private var document: Deliverable!

    override func setUp() async throws {
        database = try DatabaseManager.inMemory()
        transcripts = GRDBTranscriptionStore(database: database)
        store = GRDBDeliverableStore(database: database)
        var row = Transcription(sourceType: .text, fileName: "Text", status: .completed)
        row.rawTranscript = "Synthetic source."
        try await transcripts.insert(row)
        document = Deliverable(
            transcriptionID: row.id, promptID: nil, promptVersionID: nil, title: "Summary", engineID: "fake.engine",
            provider: "Fake", model: "fake-1", locality: .onDevice, text: "Synthetic summary, first draft.",
            privacyClass: .personal, createdAt: Date(timeIntervalSinceReferenceDate: 780_000_000))
        try await store.insertDeliverable(document)
    }

    private func draft(
        _ text: String, origin: DeliverableVersion.Origin = .spokenEdit, instruction: String? = "Make it shorter",
        privacyClass: PrivacyClass = .personal
    ) -> DeliverableVersionDraft {
        DeliverableVersionDraft(
            text: text, origin: origin, instruction: instruction, engineID: "fake.engine", provider: "Fake",
            model: "fake-1", locality: .onDevice, privacyClass: privacyClass,
            createdAt: Date(timeIntervalSinceReferenceDate: 780_000_100))
    }

    func testTheFirstEditKeepsTheOriginalAsVersionOne() async throws {
        let before = try await store.fetchDeliverableVersions(deliverableID: document.id)
        XCTAssertTrue(before.isEmpty)

        let result = try await store.appendDeliverableVersion(
            draft("Synthetic summary, shorter."), deliverableID: document.id)
        let appended = try XCTUnwrap(result)
        XCTAssertEqual(appended.deliverable.text, "Synthetic summary, shorter.")
        XCTAssertEqual(appended.versions.map(\.versionNumber), [1, 2])
        XCTAssertEqual(appended.versions[0].origin, .original)
        XCTAssertEqual(appended.versions[0].text, "Synthetic summary, first draft.", "the earlier text is kept")
        XCTAssertEqual(appended.versions[1].origin, .spokenEdit)
        XCTAssertEqual(appended.versions[1].instruction, "Make it shorter")
        let stored = try await store.fetchDeliverable(id: document.id)
        XCTAssertEqual(stored?.text, "Synthetic summary, shorter.")
        XCTAssertNil(stored?.editedAt, "a model's edit is not the person's hand edit")
    }

    func testAHandEditIsKeptBeforeTheNextChange() async throws {
        _ = try await store.appendDeliverableVersion(draft("Version two text."), deliverableID: document.id)
        _ = try await store.updateDeliverableText(id: document.id, text: "The person typed this.")
        let result = try await store.appendDeliverableVersion(
            draft("Version four text.", origin: .typedEdit), deliverableID: document.id)
        let versions = try XCTUnwrap(result).versions
        XCTAssertEqual(versions.map(\.origin), [.original, .spokenEdit, .handEdit, .typedEdit])
        XCTAssertEqual(versions[2].text, "The person typed this.")
    }

    func testRestoreAppendsAndNothingIsOverwritten() async throws {
        _ = try await store.appendDeliverableVersion(draft("Version two text."), deliverableID: document.id)
        let restore = DeliverableVersionDraft(
            text: "Synthetic summary, first draft.", origin: .restore, restoredFrom: 1, privacyClass: .personal)
        let result = try await store.appendDeliverableVersion(restore, deliverableID: document.id)
        let versions = try XCTUnwrap(result).versions
        XCTAssertEqual(versions.map(\.versionNumber), [1, 2, 3])
        XCTAssertEqual(versions[2].origin, .restore)
        XCTAssertEqual(versions[2].restoredFrom, 1)
        XCTAssertEqual(versions[1].text, "Version two text.", "the version restored over stays")
        XCTAssertEqual(try XCTUnwrap(result).deliverable.text, "Synthetic summary, first draft.")
    }

    func testAClinicalEditRaisesTheDocumentNeverLowers() async throws {
        let raised = try await store.appendDeliverableVersion(
            draft("Clinical text.", privacyClass: .clinical), deliverableID: document.id)
        XCTAssertEqual(raised?.deliverable.privacyClass, .clinical)
        let after = try await store.appendDeliverableVersion(
            draft("Later text.", privacyClass: .general), deliverableID: document.id)
        XCTAssertEqual(after?.deliverable.privacyClass, .clinical)
        XCTAssertEqual(after?.versions.last?.privacyClass, .clinical)
    }

    func testAGoneDocumentStoresNothing() async throws {
        let result = try await store.appendDeliverableVersion(draft("Text."), deliverableID: UUID())
        XCTAssertNil(result)
    }

    func testTheDatabaseRefusesToChangeOrDeleteAVersion() async throws {
        _ = try await store.appendDeliverableVersion(draft("Version two text."), deliverableID: document.id)
        let first = try await store.fetchDeliverableVersions(deliverableID: document.id).first
        let id = try XCTUnwrap(first?.id)
        do {
            try await database.writer.write { db in
                guard var record = try DeliverableVersionRecord.fetchOne(db, key: id) else { return }
                record.text = "Overwritten."
                try record.update(db)
            }
            XCTFail("a version was changed")
        } catch {
            XCTAssertTrue("\(error)".contains("immutable"), "\(error)")
        }
        do {
            _ = try await database.writer.write { db in try DeliverableVersionRecord.deleteOne(db, key: id) }
            XCTFail("a version was deleted while its document exists")
        } catch {
            XCTAssertTrue("\(error)".contains("append-only"), "\(error)")
        }
        let versions = try await store.fetchDeliverableVersions(deliverableID: document.id)
        XCTAssertEqual(versions.first?.text, "Synthetic summary, first draft.")
    }

    func testDeletingTheDocumentOrItsTranscriptRemovesItsVersions() async throws {
        _ = try await store.appendDeliverableVersion(draft("Version two text."), deliverableID: document.id)
        try await store.deleteDeliverable(id: document.id)
        let count = try await database.writer.read { db in try DeliverableVersionRecord.fetchCount(db) }
        XCTAssertEqual(count, 0)

        let second = Deliverable(
            transcriptionID: document.transcriptionID, promptID: nil, promptVersionID: nil, title: "Summary",
            engineID: "fake.engine", provider: "Fake", model: nil, locality: .onDevice, text: "Another.",
            privacyClass: .personal)
        try await store.insertDeliverable(second)
        _ = try await store.appendDeliverableVersion(draft("Another, edited."), deliverableID: second.id)
        try await transcripts.delete(id: document.transcriptionID)
        let left = try await database.writer.read { db in try DeliverableVersionRecord.fetchCount(db) }
        XCTAssertEqual(left, 0, "deleting the transcript deletes its documents and their versions")
    }
}
