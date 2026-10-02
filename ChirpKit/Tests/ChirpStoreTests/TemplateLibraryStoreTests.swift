import ChirpCore
import GRDB
import XCTest

@testable import ChirpStore

/// Plan 026 Step 2: the person's own templates in the real store — create, edit as versions, hide, reorder per
/// section, soft delete and restore — and built-in upgrades that keep the person's order and visibility.
final class TemplateLibraryStoreTests: XCTestCase {
    private var database: DatabaseManager!
    private var store: GRDBDeliverableStore!

    private static let summaryID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private static let soapID = UUID(uuidString: "11111111-1111-1111-1111-111111111115")!
    private static let polishID = UUID(uuidString: "11111111-1111-1111-1111-111111111121")!

    override func setUp() async throws {
        database = try DatabaseManager.inMemory()
        store = GRDBDeliverableStore(database: database)
        try await store.installBuiltInTemplates(Self.builtIns())
    }

    private static func builtIns(summaryRevision: Int = 1, summaryText: String = "Summarize.")
        -> [BuiltInPromptTemplate]
    {
        [
            BuiltInPromptTemplate(
                id: summaryID, canonicalKey: "summary", revision: summaryRevision, name: "Summary",
                category: .deliverable, content: summaryText, sortOrder: 0),
            BuiltInPromptTemplate(
                id: soapID, canonicalKey: "soap-note", revision: 1, name: "SOAP note", category: .deliverable,
                content: "Write a SOAP note.", outputPrivacyClass: .clinical, sortOrder: 4),
            BuiltInPromptTemplate(
                id: polishID, canonicalKey: "polish", revision: 1, name: "Polish", category: .transform,
                content: "Polish the text.", sortOrder: 100),
        ]
    }

    private func draft(
        _ name: String = "Clinic SOAP",
        _ category: PromptTemplate.Category = .deliverable,
        _ instructions: String = "Use our clinic headings.",
        clinical: Bool = true
    ) -> TemplateDraft {
        TemplateDraft(name: name, category: category, instructions: instructions, makesClinicalDocuments: clinical)
    }

    private func section(_ category: PromptTemplate.Category) async throws -> [PromptTemplate] {
        try await store.fetchTemplates().filter { $0.category == category }
    }

    private func assertThrows(
        _ expected: TemplateLibraryError,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: () async throws -> Void
    ) async {
        do {
            try await body()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? TemplateLibraryError, expected, file: file, line: line)
        }
    }

    private func insertDocument(promptID: UUID, versionID: UUID, title: String) async throws -> Deliverable {
        var row = Transcription(fileName: "synthetic.m4a", status: .completed, privacyClass: .personal)
        row.rawTranscript = "Synthetic transcript about the blue heron."
        try await GRDBTranscriptionStore(database: database).insert(row)
        let document = Deliverable(
            transcriptionID: row.id, promptID: promptID, promptVersionID: versionID, title: title,
            engineID: "fake.engine", provider: "Fake", model: "fake-1", locality: .onDevice,
            text: "Synthetic document.", privacyClass: .clinical)
        try await store.insertDeliverable(document)
        return document
    }

    // MARK: Create and edit

    func testAUserTemplateStartsAtVersionOneLastInItsSection() async throws {
        let mine = try await store.createUserTemplate(draft("  Clinic\nSOAP ", .deliverable, "\n Use our headings. \n"))
        XCTAssertEqual(mine.name, "Clinic SOAP")
        XCTAssertFalse(mine.isBuiltIn)
        XCTAssertNil(mine.canonicalKey)
        XCTAssertNil(mine.canonicalRevision)
        XCTAssertEqual(mine.outputPrivacyClass, .clinical)
        XCTAssertTrue(mine.isVisible)
        XCTAssertNil(mine.userCustomizedAt)
        XCTAssertEqual(mine.sortOrder, 5, "after SOAP note (4), the highest in Documents")
        let versions = try await store.fetchVersions(promptID: mine.id)
        XCTAssertEqual(versions.map(\.versionNumber), [1])
        XCTAssertEqual(versions.first?.origin, .user)
        XCTAssertEqual(versions.first?.content, "Use our headings.")
        XCTAssertEqual(mine.activeVersionID, versions.first?.id)
        let value1 = try await section(.deliverable).map(\.name)
        XCTAssertEqual(value1, ["Summary", "SOAP note", "Clinic SOAP"])

        let rewrite = try await store.createUserTemplate(
            draft("Plain words", .transform, "Simpler words.", clinical: false))
        XCTAssertEqual(rewrite.sortOrder, 101, "last among Rewrites, not after every template")
        XCTAssertNil(rewrite.outputPrivacyClass)
        let value2 = try await section(.transform).map(\.name)
        XCTAssertEqual(value2, ["Polish", "Plain words"])
    }

    func testAnInvalidDraftIsRefusedAndNothingIsStored() async throws {
        await assertThrows(.problem(.emptyName)) { _ = try await self.store.createUserTemplate(self.draft("  ")) }
        await assertThrows(.problem(.reservedTag("<transcript>"))) {
            _ = try await self.store.createUserTemplate(self.draft("X", .deliverable, "Read <transcript>."))
        }
        await assertThrows(.problem(.instructionsTooLong(count: 4_001))) {
            _ = try await self.store.createUserTemplate(
                self.draft("X", .deliverable, String(repeating: "y", count: 4_001)))
        }
        let value3 = try await store.fetchTemplates().count
        XCTAssertEqual(value3, 3)
    }

    func testNamesStayUniqueAmongTemplatesNotDeleted() async throws {
        await assertThrows(.problem(.duplicateName("SOAP note"))) {
            _ = try await self.store.createUserTemplate(self.draft("soap NOTE"))
        }
        let mine = try await store.createUserTemplate(draft("Clinic SOAP"))
        try await store.setTemplateVisible(id: mine.id, isVisible: false)
        await assertThrows(
            .problem(.duplicateName("Clinic SOAP")),
            {
                _ = try await self.store.createUserTemplate(self.draft("CLINIC soap"))
            })
        // Renaming yourself to another case is fine.
        let recased = try await store.updateUserTemplate(id: mine.id, with: draft("clinic soap"))
        XCTAssertEqual(recased.name, "clinic soap")
        // A deleted one frees its name.
        try await store.deleteUserTemplate(id: mine.id)
        let again = try await store.createUserTemplate(draft("Clinic SOAP"))
        XCTAssertNotEqual(again.id, mine.id)
    }

    func testRenamingAddsNoVersionAndNewTextAddsOne() async throws {
        let mine = try await store.createUserTemplate(draft("Clinic SOAP", .deliverable, "Headings A."))
        let v1 = try await store.fetchVersions(promptID: mine.id)

        let renamed = try await store.updateUserTemplate(
            id: mine.id, with: draft("Referral letter", .transform, "  Headings A.\n", clinical: false))
        XCTAssertEqual(renamed.name, "Referral letter")
        XCTAssertEqual(renamed.category, .transform)
        XCTAssertNil(renamed.outputPrivacyClass, "the switch is saved on the row")
        XCTAssertEqual(renamed.activeVersionID, mine.activeVersionID)
        XCTAssertEqual(renamed.sortOrder, 101, "a new kind puts it last in its new section")
        let value4 = try await store.fetchVersions(promptID: mine.id)
        XCTAssertEqual(value4, v1, "no version for a rename")

        let edited = try await store.updateUserTemplate(
            id: mine.id, with: draft("Referral letter", .transform, "Headings B.", clinical: true))
        let versions = try await store.fetchVersions(promptID: mine.id)
        XCTAssertEqual(versions.map(\.versionNumber), [1, 2])
        XCTAssertEqual(versions.map(\.origin), [.user, .user])
        XCTAssertEqual(versions.first, v1.first, "version 1 is byte-identical")
        XCTAssertEqual(versions.last?.content, "Headings B.")
        XCTAssertEqual(edited.activeVersionID, versions.last?.id)
        XCTAssertEqual(edited.outputPrivacyClass, .clinical)
        XCTAssertEqual(edited.sortOrder, 101, "the same kind keeps its place")
    }

    func testADocumentKeepsItsVersionAndTitleAfterAnEdit() async throws {
        let mine = try await store.createUserTemplate(draft("Clinic SOAP", .deliverable, "Headings A."))
        let document = try await insertDocument(promptID: mine.id, versionID: mine.activeVersionID, title: mine.name)
        let before = try await store.fetchDeliverable(id: document.id)
        _ = try await store.updateUserTemplate(id: mine.id, with: draft("SOAP (clinic)", .deliverable, "Headings B."))

        let stored = try await store.fetchDeliverable(id: document.id)
        XCTAssertEqual(stored, before, "the document row is untouched")
        XCTAssertEqual(stored?.promptVersionID, mine.activeVersionID)
        XCTAssertEqual(stored?.title, "Clinic SOAP")
        let value5 = try await store.fetchVersion(id: mine.activeVersionID)?.content
        XCTAssertEqual(value5, "Headings A.")
        let value6 = try await store.countDeliverables(promptID: mine.id)
        XCTAssertEqual(value6, 1)
    }

    // MARK: Built-ins

    func testBuiltInsCanBeHiddenAndMovedButNotEditedOrDeleted() async throws {
        let before = try await store.fetchTemplate(id: Self.soapID)
        await assertThrows(.builtInIsReadOnly) {
            _ = try await self.store.updateUserTemplate(id: Self.soapID, with: self.draft("SOAP note"))
        }
        await assertThrows(.builtInIsReadOnly) { try await self.store.deleteUserTemplate(id: Self.soapID) }
        let value7 = try await store.fetchVersions(promptID: Self.soapID).count
        XCTAssertEqual(value7, 1)

        try await store.setTemplateVisible(id: Self.soapID, isVisible: false)
        try await store.reorderTemplates(category: .deliverable, ids: [Self.soapID, Self.summaryID])
        let after = try await store.fetchTemplate(id: Self.soapID)
        XCTAssertEqual(after?.isVisible, false)
        XCTAssertEqual(after?.sortOrder, 0)
        XCTAssertNil(after?.userCustomizedAt, "hiding and moving never customize a built-in")
        XCTAssertEqual(after?.activeVersionID, before?.activeVersionID)
        XCTAssertEqual(after?.name, before?.name)
        XCTAssertNil(after?.deletedAt)
    }

    func testAHiddenTemplateIsStillListedAndFetchable() async throws {
        let mine = try await store.createUserTemplate(draft())
        try await store.setTemplateVisible(id: mine.id, isVisible: false)
        let listed = try await store.fetchTemplates()
        XCTAssertEqual(listed.first { $0.id == mine.id }?.isVisible, false)
        let value8 = try await store.fetchTemplate(id: mine.id)?.isVisible
        XCTAssertEqual(value8, false)
        let value9 = try await store.fetchVersion(id: mine.activeVersionID)
        XCTAssertNotNil(value9)
        try await store.setTemplateVisible(id: mine.id, isVisible: true)
        let value10 = try await store.fetchTemplate(id: mine.id)?.isVisible
        XCTAssertEqual(value10, true)
    }

    // MARK: Order

    func testReorderWritesOneSectionAndRefusesPartialOrMixedLists() async throws {
        let mine = try await store.createUserTemplate(draft())
        let rewrite = try await store.createUserTemplate(draft("Plain words", .transform, "Simpler.", clinical: false))
        let deleted = try await store.createUserTemplate(draft("Old one"))
        try await store.deleteUserTemplate(id: deleted.id)

        try await store.reorderTemplates(category: .deliverable, ids: [mine.id, Self.soapID, Self.summaryID])
        let documents = try await section(.deliverable)
        XCTAssertEqual(documents.map(\.id), [mine.id, Self.soapID, Self.summaryID])
        XCTAssertEqual(documents.map(\.sortOrder), [0, 1, 2])
        let value11 = try await section(.transform).map(\.sortOrder)
        XCTAssertEqual(value11, [100, 101], "the other section is untouched")

        try await store.reorderTemplates(category: .transform, ids: [rewrite.id, Self.polishID])
        let rewrites = try await section(.transform)
        XCTAssertEqual(rewrites.map(\.id), [rewrite.id, Self.polishID])
        XCTAssertEqual(rewrites.map(\.sortOrder), [1000, 1001])

        let refused: [(PromptTemplate.Category, [UUID])] = [
            (.deliverable, [mine.id, Self.soapID]),  // partial
            (.deliverable, [mine.id, Self.soapID, Self.summaryID, Self.polishID]),  // mixed
            (.deliverable, [mine.id, Self.soapID, Self.soapID]),  // repeated
            (.deliverable, [mine.id, Self.soapID, Self.summaryID, deleted.id]),  // a deleted one
            (.transform, [rewrite.id, UUID()]),  // unknown
        ]
        for (category, ids) in refused {
            await assertThrows(.invalidOrder) { try await self.store.reorderTemplates(category: category, ids: ids) }
        }
        let value12 = try await section(.deliverable).map(\.id)
        XCTAssertEqual(value12, [mine.id, Self.soapID, Self.summaryID])
        let value13 = try await section(.transform).map(\.id)
        XCTAssertEqual(value13, [rewrite.id, Self.polishID])
    }

    func testABuiltInUpgradeKeepsTheOrderAndVisibility() async throws {
        try await store.reorderTemplates(category: .deliverable, ids: [Self.soapID, Self.summaryID])
        try await store.setTemplateVisible(id: Self.summaryID, isVisible: false)

        try await store.installBuiltInTemplates(Self.builtIns(summaryRevision: 2, summaryText: "Summarize briefly."))

        let summary = try await store.fetchTemplate(id: Self.summaryID)
        XCTAssertEqual(summary?.canonicalRevision, 2)
        let versions = try await store.fetchVersions(promptID: Self.summaryID)
        XCTAssertEqual(versions.map(\.origin), [.builtIn, .systemUpdate], "a hidden built-in is still upgraded")
        XCTAssertEqual(summary?.activeVersionID, versions.last?.id)
        XCTAssertEqual(versions.last?.content, "Summarize briefly.")
        XCTAssertEqual(summary?.sortOrder, 1, "the person's order stays")
        XCTAssertEqual(summary?.isVisible, false, "the person's choice stays")
        let value14 = try await section(.deliverable).map(\.id)
        XCTAssertEqual(value14, [Self.soapID, Self.summaryID])
    }

    // MARK: Delete and restore

    func testDeletingIsSoftAndKeepsVersionsAndDocuments() async throws {
        let mine = try await store.createUserTemplate(draft())
        let document = try await insertDocument(promptID: mine.id, versionID: mine.activeVersionID, title: mine.name)

        try await store.deleteUserTemplate(id: mine.id)

        let value15 = try await store.fetchTemplates().contains { $0.id == mine.id }

        XCTAssertFalse(value15)
        let deleted = try await store.fetchDeletedTemplates()
        XCTAssertEqual(deleted.map(\.id), [mine.id])
        XCTAssertNotNil(deleted.first?.deletedAt)
        let value16 = try await store.fetchTemplate(id: mine.id)?.deletedAt
        XCTAssertNotNil(value16, "fetch by id still finds it")
        let value17 = try await store.fetchVersion(id: mine.activeVersionID)?.content
        XCTAssertEqual(value17, "Use our clinic headings.")
        let value18 = try await store.fetchDeliverable(id: document.id)?.promptID
        XCTAssertEqual(value18, mine.id)
        let value19 = try await store.fetchDeliverable(id: document.id)?.promptVersionID
        XCTAssertEqual(value19, mine.activeVersionID)
        let value20 = try await store.countDeliverables(promptID: mine.id)
        XCTAssertEqual(value20, 1)
        // Deleting again changes nothing.
        try await store.deleteUserTemplate(id: mine.id)
        let value21 = try await store.fetchDeletedTemplates().map(\.deletedAt)
        XCTAssertEqual(value21, deleted.map(\.deletedAt))
    }

    func testDeletedTemplatesAreListedNewestDeleteFirst() async throws {
        let first = try await store.createUserTemplate(draft("First"))
        let second = try await store.createUserTemplate(draft("Second"))
        try await store.deleteUserTemplate(id: second.id)
        try await store.deleteUserTemplate(id: first.id)
        // Stored dates have millisecond precision: give the two deletes distinct, known times.
        try await database.writer.write { db in
            for (id, seconds) in [(second.id, 100.0), (first.id, 200.0)] {
                var record = try XCTUnwrap(try PromptRecord.fetchOne(db, key: id))
                record.deletedAt = Date(timeIntervalSinceReferenceDate: 780_000_000 + seconds)
                try record.update(db)
            }
        }
        let value22 = try await store.fetchDeletedTemplates().map(\.id)
        XCTAssertEqual(value22, [first.id, second.id])
    }

    func testRestoringBringsItBackAndRenamesWhenTheNameWasTaken() async throws {
        let mine = try await store.createUserTemplate(draft("Clinic SOAP"))
        try await store.deleteUserTemplate(id: mine.id)
        let restored = try await store.restoreDeletedTemplate(id: mine.id)
        XCTAssertNil(restored.deletedAt)
        XCTAssertEqual(restored.name, "Clinic SOAP")
        XCTAssertEqual(restored.activeVersionID, mine.activeVersionID, "the id and version never changed")
        let value23 = try await store.fetchDeletedTemplates().isEmpty
        XCTAssertTrue(value23)

        try await store.deleteUserTemplate(id: mine.id)
        _ = try await store.createUserTemplate(draft("clinic soap"))
        let renamed = try await store.restoreDeletedTemplate(id: mine.id)
        XCTAssertEqual(renamed.name, "Clinic SOAP (restored)")
        let value24 = try await section(.deliverable).last?.id
        XCTAssertEqual(value24, mine.id, "back last in its section")
    }

    func testUpdatingOrHidingADeletedTemplateIsRefused() async throws {
        let mine = try await store.createUserTemplate(draft())
        try await store.deleteUserTemplate(id: mine.id)
        await assertThrows(.templateDeleted) {
            _ = try await self.store.updateUserTemplate(id: mine.id, with: self.draft("Renamed"))
        }
        await assertThrows(.templateDeleted) { try await self.store.setTemplateVisible(id: mine.id, isVisible: false) }
        let missing = UUID()
        await assertThrows(.templateNotFound) {
            _ = try await self.store.updateUserTemplate(id: missing, with: self.draft())
        }
        await assertThrows(.templateNotFound) { try await self.store.setTemplateVisible(id: missing, isVisible: true) }
        await assertThrows(.templateNotFound) { try await self.store.deleteUserTemplate(id: missing) }
        await assertThrows(.templateNotFound) { _ = try await self.store.restoreDeletedTemplate(id: missing) }
        let value25 = try await store.fetchTemplate(id: mine.id)?.name
        XCTAssertEqual(value25, "Clinic SOAP")
        let value26 = try await store.fetchTemplate(id: mine.id)?.isVisible
        XCTAssertEqual(value26, true)
    }
}
