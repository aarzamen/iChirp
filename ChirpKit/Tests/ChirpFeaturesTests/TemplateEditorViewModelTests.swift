import ChirpCore
import Foundation
import XCTest

@testable import ChirpFeatures

/// Plan 026 Step 5: the template editor's model — start from a template or a blank page, problems as sentences, save as
/// a new template or a new version, earlier versions' text, and the discard question. Every text is synthetic.
@MainActor
final class TemplateEditorViewModelTests: XCTestCase {
    private var store: FakeDeliverableStore!
    private var saved = 0

    override func setUp() async throws {
        store = FakeDeliverableStore()
        try await store.installBuiltInTemplates(BuiltInTemplates.all)
        saved = 0
    }

    private func editor(_ mode: TemplateEditorViewModel.Mode) async -> TemplateEditorViewModel {
        let model = TemplateEditorViewModel(mode: mode, store: store, didSave: { [unowned self] _ in self.saved += 1 })
        await model.load()
        return model
    }

    private func soap() async throws -> PromptTemplate {
        let template = try await store.fetchTemplate(id: BuiltInTemplates.soapNote.id)
        return try XCTUnwrap(template)
    }

    func testStartingFromSOAPNoteCopiesItsTextKindAndClinicalSwitch() async throws {
        let model = await editor(.new(startingFrom: try await soap()))
        XCTAssertEqual(model.name, "SOAP note copy")
        XCTAssertEqual(model.kind, .deliverable)
        XCTAssertEqual(model.instructions, BuiltInTemplates.soapNote.content)
        XCTAssertTrue(model.makesClinicalDocuments)
        XCTAssertNil(model.problem)
        XCTAssertFalse(model.hasChanges, "an untouched copy needs no discard question")
        XCTAssertTrue(model.versions.isEmpty)
        XCTAssertTrue(model.isNew)

        // Changing the starting point replaces the fields.
        let fetchedPolish = try await store.fetchTemplate(id: BuiltInTemplates.polish.id)
        let polish = try XCTUnwrap(fetchedPolish)
        await model.start(from: polish)
        XCTAssertEqual(model.name, "Polish copy")
        XCTAssertEqual(model.kind, .transform)
        XCTAssertFalse(model.makesClinicalDocuments)
        XCTAssertEqual(model.startingPoint?.id, polish.id)
    }

    func testStartingBlank() async throws {
        let model = await editor(.new(startingFrom: nil))
        XCTAssertEqual(model.name, "")
        XCTAssertEqual(model.kind, .deliverable)
        XCTAssertEqual(model.instructions, "")
        XCTAssertFalse(model.makesClinicalDocuments)
        XCTAssertEqual(model.problem, .emptyName)
        XCTAssertFalse(model.canSave)
        XCTAssertFalse(model.hasChanges)

        await model.start(from: try await soap())
        await model.start(from: nil)
        XCTAssertEqual(model.name, "")
        XCTAssertFalse(model.makesClinicalDocuments)
    }

    func testProblemsAreSentencesAndSaveIsRefused() async throws {
        let model = await editor(.new(startingFrom: nil))
        model.name = "soap note"
        model.instructions = "Headings."
        XCTAssertEqual(model.problem, .duplicateName("SOAP note"))
        XCTAssertEqual(model.problemSentence, "“SOAP note” is already a template. Choose another name.")
        XCTAssertFalse(model.canSave)
        let refused = await model.save()
        XCTAssertNil(refused)
        XCTAssertEqual(model.saveError, "“SOAP note” is already a template. Choose another name.")
        XCTAssertEqual(saved, 0)
        let count = try await store.fetchTemplates().count
        XCTAssertEqual(count, 9)

        model.name = "Clinic SOAP"
        model.instructions = String(repeating: "x", count: 4_001)
        XCTAssertEqual(model.problem, .instructionsTooLong(count: 4_001))
        XCTAssertEqual(model.characterCount, 4_001)
        model.instructions = "Use <transcript> here."
        XCTAssertEqual(model.problem, .reservedTag("<transcript>"))
        model.instructions = "Headings."
        XCTAssertNil(model.problem)
        XCTAssertTrue(model.canSave)
    }

    func testSavingANewTemplatePutsItLastInItsSection() async throws {
        let model = await editor(.new(startingFrom: try await soap()))
        model.name = "Clinic SOAP"
        model.instructions = "Use our clinic headings."
        let created = await model.save()
        let template = try XCTUnwrap(created)
        XCTAssertNil(model.saveError)
        XCTAssertEqual(saved, 1)
        XCTAssertEqual(template.name, "Clinic SOAP")
        XCTAssertEqual(template.outputPrivacyClass, .clinical)
        XCTAssertFalse(template.isBuiltIn)
        let documents = try await store.fetchTemplates().filter { $0.category == .deliverable }
        XCTAssertEqual(documents.last?.id, template.id)
        let soapVersions = try await store.fetchVersions(promptID: BuiltInTemplates.soapNote.id)
        XCTAssertEqual(soapVersions.count, 1, "SOAP note is untouched")
        XCTAssertFalse(model.hasChanges, "saved: nothing left to discard")
        XCTAssertEqual(model.mode, .edit(template), "a second Save edits what the first one made")
    }

    func testRenamingOnlyAddsNoVersion() async throws {
        let mine = try await store.createUserTemplate(
            TemplateDraft(
                name: "Clinic SOAP", category: .deliverable, instructions: "Headings A.", makesClinicalDocuments: true))
        let model = await editor(.edit(mine))
        XCTAssertFalse(model.isNew)
        XCTAssertEqual(model.name, "Clinic SOAP")
        XCTAssertEqual(model.instructions, "Headings A.")
        XCTAssertEqual(model.versions.map(\.versionNumber), [1])
        XCTAssertNil(model.nextVersionNumber, "the text did not change")

        model.name = "SOAP (clinic)"
        model.makesClinicalDocuments = false
        XCTAssertTrue(model.hasChanges)
        let updated = await model.save()
        XCTAssertEqual(updated?.name, "SOAP (clinic)")
        XCTAssertNil(updated?.outputPrivacyClass)
        let versions = try await store.fetchVersions(promptID: mine.id)
        XCTAssertEqual(versions.count, 1)
    }

    func testChangingTheTextAddsAVersion() async throws {
        let mine = try await store.createUserTemplate(
            TemplateDraft(
                name: "Clinic SOAP", category: .deliverable, instructions: "Headings A.", makesClinicalDocuments: true))
        let model = await editor(.edit(mine))
        model.instructions = "Headings B."
        XCTAssertEqual(model.nextVersionNumber, 2)
        XCTAssertEqual(
            model.versionNote, "Saving makes version 2. Documents made before keep the version they used.")
        let updated = await model.save()
        XCTAssertNotEqual(updated?.activeVersionID, mine.activeVersionID)
        XCTAssertEqual(model.versions.map(\.versionNumber), [2, 1], "newest first, reloaded after the save")
        XCTAssertEqual(model.versions.last?.content, "Headings A.")
        XCTAssertNil(model.nextVersionNumber)
    }

    func testUsingAnEarlierVersionsTextChangesOnlyTheDraft() async throws {
        let mine = try await store.createUserTemplate(
            TemplateDraft(
                name: "Clinic SOAP", category: .deliverable, instructions: "Headings A.", makesClinicalDocuments: true))
        _ = try await store.updateUserTemplate(
            id: mine.id,
            with: TemplateDraft(
                name: "Clinic SOAP", category: .deliverable, instructions: "Headings B.", makesClinicalDocuments: true))
        let fetched = try await store.fetchTemplate(id: mine.id)
        let current = try XCTUnwrap(fetched)
        let model = await editor(.edit(current))
        XCTAssertEqual(model.instructions, "Headings B.")
        let first = try XCTUnwrap(model.versions.last)
        XCTAssertEqual(first.versionNumber, 1)

        model.useText(of: first)
        XCTAssertEqual(model.instructions, "Headings A.")
        XCTAssertTrue(model.hasChanges)
        XCTAssertEqual(model.nextVersionNumber, 3, "using old text makes a new version; history never changes")
        let stored = try await store.fetchTemplate(id: mine.id)
        XCTAssertEqual(stored?.activeVersionID, current.activeVersionID, "nothing saved yet")
    }

    func testHasChangesDrivesTheDiscardQuestion() async throws {
        let model = await editor(.new(startingFrom: nil))
        XCTAssertFalse(model.hasChanges)
        model.name = "X"
        XCTAssertTrue(model.hasChanges)
        model.name = ""
        XCTAssertFalse(model.hasChanges)
        model.makesClinicalDocuments = true
        XCTAssertTrue(model.hasChanges)
        model.makesClinicalDocuments = false
        model.kind = .transform
        XCTAssertTrue(model.hasChanges)
    }

    func testABuiltInOpensOnlyAsACopy() async throws {
        let builtIn = try await soap()
        let model = await editor(.edit(builtIn))
        XCTAssertEqual(model.mode, .new(startingFrom: builtIn))
        XCTAssertTrue(model.isNew)
        XCTAssertEqual(model.name, "SOAP note copy")
        let created = await model.save()
        XCTAssertNotEqual(created?.id, builtIn.id)
        let versions = try await store.fetchVersions(promptID: builtIn.id)
        XCTAssertEqual(versions.count, 1, "the built-in is untouched")
    }

    func testSavingADeletedTemplateSaysRestoreFirst() async throws {
        let mine = try await store.createUserTemplate(
            TemplateDraft(
                name: "Clinic SOAP", category: .deliverable, instructions: "Headings A.", makesClinicalDocuments: true))
        let model = await editor(.edit(mine))
        try await store.deleteUserTemplate(id: mine.id)
        model.instructions = "Headings B."
        let result = await model.save()
        XCTAssertNil(result)
        XCTAssertEqual(model.saveError, "This template was deleted. Restore it first.")
        XCTAssertTrue(model.hasChanges, "the typed text stays")
    }
}
