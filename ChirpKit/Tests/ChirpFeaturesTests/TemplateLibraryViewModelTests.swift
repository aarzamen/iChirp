import ChirpCore
import Foundation
import XCTest

@testable import ChirpFeatures

/// Plan 026 Step 5: the Templates screen's model — sections in the person's order, hide and show, move, the actions a
/// row offers, the delete question, delete and restore, and honest errors. Every text is synthetic.
@MainActor
final class TemplateLibraryViewModelTests: XCTestCase {
    private var store: FakeDeliverableStore!
    private var changes = 0
    private var recipes: [UUID: [String]] = [:]

    override func setUp() async throws {
        store = FakeDeliverableStore()
        try await store.installBuiltInTemplates(BuiltInTemplates.all)
        changes = 0
        recipes = [:]
    }

    private func makeModel() -> TemplateLibraryViewModel {
        TemplateLibraryViewModel(
            store: store, recipesUsing: { [unowned self] id in self.recipes[id] ?? [] },
            didChange: { [unowned self] in self.changes += 1 })
    }

    private func mine(_ name: String = "Clinic SOAP", _ category: PromptTemplate.Category = .deliverable) async throws
        -> PromptTemplate
    {
        try await store.createUserTemplate(
            TemplateDraft(
                name: name, category: category, instructions: "Synthetic headings.", makesClinicalDocuments: true))
    }

    private func names(_ templates: [PromptTemplate]) -> [String] { templates.map(\.name) }

    func testSectionsHoldEveryTemplateInOrderWithHiddenOnesMarked() async throws {
        let clinic = try await mine()
        let plain = try await mine("Plain words", .transform)
        try await store.setTemplateVisible(id: BuiltInTemplates.agenda.id, isVisible: false)
        let model = makeModel()
        await model.load()

        XCTAssertNil(model.loadError)
        XCTAssertTrue(model.hasLoaded)
        XCTAssertEqual(
            names(model.documents), ["Summary", "Meeting notes", "Action items", "Agenda", "SOAP note", "Clinic SOAP"])
        XCTAssertEqual(names(model.rewrites), ["Polish", "Distill", "Decide", "Brief", "Plain words"])
        XCTAssertEqual(model.documents.first { $0.id == BuiltInTemplates.agenda.id }?.isVisible, false)
        XCTAssertEqual(model.hiddenCount, 1)
        XCTAssertTrue(model.hasTemplatesOfYourOwn)
        XCTAssertEqual(model.templates(in: .deliverable).last?.id, clinic.id)
        XCTAssertEqual(model.templates(in: .transform).last?.id, plain.id)
        XCTAssertEqual(model.startingPoints.map(\.name), names(model.documents) + names(model.rewrites))
        XCTAssertTrue(model.deleted.isEmpty)
    }

    func testANewLibraryHasNoTemplatesOfYourOwn() async {
        let model = makeModel()
        await model.load()
        XCTAssertFalse(model.hasTemplatesOfYourOwn, "the screen shows the empty-state card")
        XCTAssertEqual(model.documents.count, 5)
        XCTAssertEqual(model.rewrites.count, 4)
    }

    func testHideAndShowSaveAndTellTheTransformsTab() async throws {
        let model = makeModel()
        await model.load()
        let soap = try XCTUnwrap(model.documents.first { $0.id == BuiltInTemplates.soapNote.id })

        await model.setVisible(soap, false)
        XCTAssertEqual(changes, 1)
        XCTAssertEqual(model.documents.first { $0.id == soap.id }?.isVisible, false)
        let stored = try await store.fetchTemplate(id: soap.id)
        XCTAssertEqual(stored?.isVisible, false)
        XCTAssertNil(stored?.userCustomizedAt)

        await model.setVisible(soap, true)
        XCTAssertEqual(changes, 2)
        XCTAssertEqual(model.documents.first { $0.id == soap.id }?.isVisible, true)
        XCTAssertNil(model.actionError)
    }

    func testMoveUpAndDownStayInTheirSection() async throws {
        let clinic = try await mine()
        let model = makeModel()
        await model.load()
        let summary = try XCTUnwrap(model.documents.first)
        let polish = try XCTUnwrap(model.rewrites.first)
        let brief = try XCTUnwrap(model.rewrites.last)

        XCTAssertFalse(model.canMoveUp(summary), "the top edge is disabled")
        XCTAssertTrue(model.canMoveDown(summary))
        XCTAssertFalse(model.canMoveDown(clinic), "the bottom edge is disabled")
        XCTAssertFalse(model.canMoveUp(polish), "Rewrites have their own top")
        XCTAssertFalse(model.canMoveDown(brief))

        await model.moveUp(clinic)
        XCTAssertEqual(
            names(model.documents), ["Summary", "Meeting notes", "Action items", "Agenda", "Clinic SOAP", "SOAP note"])
        XCTAssertEqual(
            names(model.rewrites), ["Polish", "Distill", "Decide", "Brief"], "the other section is untouched")
        XCTAssertEqual(changes, 1)

        await model.moveDown(summary)
        XCTAssertEqual(names(model.documents).prefix(2), ["Meeting notes", "Summary"])
        XCTAssertEqual(changes, 2)

        // Edges do nothing.
        await model.moveDown(brief)
        XCTAssertEqual(names(model.rewrites), ["Polish", "Distill", "Decide", "Brief"])
        XCTAssertEqual(changes, 2)

        // A drag writes the whole section.
        await model.move(fromOffsets: IndexSet(integer: 3), toOffset: 0, in: .transform)
        XCTAssertEqual(names(model.rewrites), ["Brief", "Polish", "Distill", "Decide"])
        XCTAssertEqual(changes, 3)
        let storedOrder = try await store.fetchTemplates().filter { $0.category == .transform }.map(\.sortOrder)
        XCTAssertEqual(storedOrder, [1_000, 1_001, 1_002, 1_003])
    }

    func testBuiltInsOfferNoEditOrDelete() async throws {
        let clinic = try await mine()
        let model = makeModel()
        await model.load()
        let soap = try XCTUnwrap(model.documents.first { $0.id == BuiltInTemplates.soapNote.id })

        XCTAssertEqual(
            model.actions(for: soap), [.duplicateAndEdit, .hide, .moveUp, .moveDown, .viewInstructions])
        XCTAssertEqual(model.actions(for: clinic), [.edit, .duplicate, .hide, .moveUp, .moveDown, .delete])
        await model.setVisible(soap, false)
        let hiddenSOAP = try XCTUnwrap(model.documents.first { $0.id == soap.id })
        XCTAssertEqual(
            model.actions(for: hiddenSOAP), [.duplicateAndEdit, .show, .moveUp, .moveDown, .viewInstructions])
    }

    func testTheDeleteQuestionSaysWhatStaysAndWhichRecipesStop() async throws {
        let clinic = try await mine()
        let model = makeModel()
        await model.load()

        var impact = await model.deleteImpact(of: clinic)
        XCTAssertEqual(impact.title, "Delete “Clinic SOAP”?")
        XCTAssertEqual(impact.message, "You can restore it later from Deleted templates.")

        let transcriptID = UUID()
        func document() -> Deliverable {
            Deliverable(
                transcriptionID: transcriptID, promptID: clinic.id, promptVersionID: clinic.activeVersionID,
                title: "Clinic SOAP", engineID: "fake.engine", provider: "Fake", model: nil, locality: .onDevice,
                text: "Synthetic.", privacyClass: .clinical)
        }
        try await store.insertDeliverable(document())
        recipes[clinic.id] = ["Dictate → Clinic SOAP"]
        impact = await model.deleteImpact(of: clinic)
        XCTAssertEqual(
            impact.message,
            "The document made with it stays and still says which template made it. The recipe “Dictate → Clinic "
                + "SOAP” stops working until you restore the template. You can restore it later from Deleted "
                + "templates.")

        for _ in 0..<11 { try await store.insertDeliverable(document()) }
        recipes[clinic.id] = ["Dictate → Clinic SOAP", "File → Clinic SOAP"]
        impact = await model.deleteImpact(of: clinic)
        XCTAssertEqual(
            impact.message,
            "The 12 documents made with it stay and still say which template made it. The recipes “Dictate → Clinic "
                + "SOAP” and “File → Clinic SOAP” stop working until you restore the template. You can restore it "
                + "later from Deleted templates.")

        recipes[clinic.id] = ["A", "B", "C"]
        impact = await model.deleteImpact(of: clinic)
        XCTAssertTrue(impact.message.contains("The recipes “A”, “B” and “C” stop working"), impact.message)
    }

    func testDeleteThenRestore() async throws {
        let clinic = try await mine()
        let model = makeModel()
        await model.load()

        await model.delete(clinic)
        XCTAssertFalse(model.documents.contains { $0.id == clinic.id })
        XCTAssertEqual(model.deleted.map(\.id), [clinic.id])
        XCTAssertEqual(changes, 1)
        XCTAssertFalse(model.hasTemplatesOfYourOwn)

        // A new template takes the name meanwhile.
        _ = try await mine("clinic soap")
        await model.load()
        await model.restore(model.deleted[0])
        XCTAssertTrue(model.deleted.isEmpty)
        XCTAssertEqual(model.documents.last?.id, clinic.id)
        XCTAssertEqual(model.documents.last?.name, "Clinic SOAP (restored)")
        XCTAssertEqual(model.notice, "Restored as “Clinic SOAP (restored)”: another template has its name.")
        XCTAssertEqual(changes, 2)

        await model.delete(clinic)
        await model.restore(model.deleted[0])
        XCTAssertNil(model.notice, "no note when the name was free")
    }

    func testAStoreErrorIsASentenceAndChangesNothing() async throws {
        let clinic = try await mine()
        let model = makeModel()
        await model.load()
        let before = (model.documents, model.rewrites)

        await store.failNextWrite(with: TemplateLibraryError.invalidOrder)
        await model.moveUp(clinic)
        XCTAssertEqual(model.actionError, "The order could not be saved. Nothing changed.")
        XCTAssertEqual(model.documents, before.0)
        XCTAssertEqual(model.rewrites, before.1)
        XCTAssertEqual(changes, 0)

        await store.failNextWrite(with: TemplateLibraryError.templateNotFound)
        await model.setVisible(clinic, false)
        XCTAssertEqual(model.actionError, "This template no longer exists.")
        XCTAssertEqual(model.documents, before.0)

        model.dismissActionError()
        XCTAssertNil(model.actionError)
        await model.setVisible(clinic, false)
        XCTAssertNil(model.actionError)
    }
}
