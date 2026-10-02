import ChirpCore
import Foundation
import XCTest

@testable import ChirpFeatures

/// Plan 026 core review fixes: a save that worked is reported as saved even when the re-read fails; the delete question
/// stays honest when the count cannot be read; a deleted template never runs; the clinical switch reaches the model on
/// a personal item; a refused order reloads the lists. Every text is synthetic.
@MainActor
final class TemplateReviewFixesTests: XCTestCase {
    private struct ReadFailure: Error, LocalizedError {
        var errorDescription: String? { "The templates could not be read." }
    }

    private func clinicDraft(_ instructions: String = "Synthetic headings.") -> TemplateDraft {
        TemplateDraft(
            name: "Clinic SOAP", category: .deliverable, instructions: instructions, makesClinicalDocuments: true)
    }

    // (1) A save that succeeded is a save, even when reading the template back fails.
    func testASaveThatSucceededIsReportedAsSavedWhenTheReReadFails() async throws {
        let store = FakeDeliverableStore()
        try await store.installBuiltInTemplates(BuiltInTemplates.all)
        var saved: [PromptTemplate] = []
        let editor = TemplateEditorViewModel(
            mode: .new(startingFrom: nil), store: store, didSave: { saved.append($0) })
        await editor.load()
        editor.name = "Clinic SOAP"
        editor.instructions = "Synthetic headings."

        await store.failNextRead(with: ReadFailure())
        let result = await editor.save()

        let template = try XCTUnwrap(result, "the template was stored, so Save reports it")
        XCTAssertEqual(saved.map(\.id), [template.id], "didSave runs so the lists reload")
        XCTAssertNil(editor.saveError)
        XCTAssertEqual(editor.loadError, "The templates could not be read.")
        XCTAssertEqual(editor.mode, .edit(template), "a second Save edits it instead of making another")
        XCTAssertFalse(editor.hasChanges, "nothing left to discard")
        let stored = try await store.fetchTemplates().filter { $0.name == "Clinic SOAP" }
        XCTAssertEqual(stored.count, 1)
    }

    // (2) When the documents cannot be counted, the question still says they stay, without a number.
    func testTheDeleteQuestionStaysHonestWhenTheCountFails() async throws {
        let store = FakeDeliverableStore()
        try await store.installBuiltInTemplates(BuiltInTemplates.all)
        let mine = try await store.createUserTemplate(clinicDraft())
        let library = TemplateLibraryViewModel(store: store, recipesUsing: { _ in [] }, didChange: {})
        await library.load()

        await store.failNextRead(with: ReadFailure())
        let impact = await library.deleteImpact(of: mine)
        XCTAssertEqual(
            impact.message, "Documents made with it stay. You can restore it later from Deleted templates.")
    }

    // (3) A deleted template never runs: nothing is sent, nothing is stored.
    func testADeletedTemplateIsRefusedBeforeAnythingIsSent() async throws {
        let harness = try await DeliverableHarness(privacy: .personal)
        let mine = try await harness.deliverables.createUserTemplate(clinicDraft())
        try await harness.deliverables.deleteUserTemplate(id: mine.id)
        let model = RecordingLanguageModel(locality: .onDevice)

        do {
            for try await _ in harness.service.generate(
                templateID: mine.id, transcriptionID: harness.transcript.id, userNotes: nil, model: model,
                override: nil)
            {}
            XCTFail("a deleted template ran")
        } catch {
            XCTAssertEqual(error as? DeliverableError, .templateDeleted)
            XCTAssertEqual(
                error.localizedDescription, "This template was deleted. Restore it in Templates to use it again.")
        }
        XCTAssertTrue(model.requests.isEmpty, "nothing was sent")
        let documents = try await harness.deliverables.fetchDeliverables(transcriptionID: harness.transcript.id)
        XCTAssertTrue(documents.isEmpty)

        // Restored, it runs again.
        _ = try await harness.deliverables.restoreDeletedTemplate(id: mine.id)
        for try await _ in harness.service.generate(
            templateID: mine.id, transcriptionID: harness.transcript.id, userNotes: nil, model: model, override: nil)
        {}
        XCTAssertEqual(model.requests.count, 1)
    }

    // (4) End to end: the clinical switch on a personal item routes clinical and the model reads the clinical rule.
    func testTheClinicalSwitchSendsTheClinicalRuleForAPersonalItem() async throws {
        let harness = try await DeliverableHarness(privacy: .personal)
        let mine = try await harness.deliverables.createUserTemplate(clinicDraft())
        let personal = try await harness.deliverables.createUserTemplate(
            TemplateDraft(
                name: "Plain letter", category: .deliverable, instructions: "Write a letter.",
                makesClinicalDocuments: false))
        let model = RecordingLanguageModel(locality: .onDevice)

        var last: DeliverableRunEvent?
        for try await event in harness.service.generate(
            templateID: mine.id, transcriptionID: harness.transcript.id, userNotes: nil, model: model, override: nil)
        {
            last = event
        }
        let request = try XCTUnwrap(model.requests.last)
        XCTAssertEqual(request.privacyClass, .clinical)
        XCTAssertTrue(request.system?.contains(DeliverablePromptAssembler.clinicalRule) ?? false)
        XCTAssertTrue(request.system?.contains(DeliverablePromptAssembler.documentRule) ?? false)
        guard case .completed(let document) = last else { return XCTFail("no document") }
        XCTAssertEqual(document.privacyClass, .clinical)

        // The same item with a template whose switch is off: no clinical rule (the item is personal).
        let plainModel = RecordingLanguageModel(locality: .onDevice)
        let other = try await DeliverableHarness(privacy: .personal)
        let plain = try await other.deliverables.createUserTemplate(
            TemplateDraft(
                name: personal.name, category: .deliverable, instructions: "Write a letter.",
                makesClinicalDocuments: false))
        for try await _ in other.service.generate(
            templateID: plain.id, transcriptionID: other.transcript.id, userNotes: nil, model: plainModel,
            override: nil)
        {}
        XCTAssertEqual(plainModel.requests.last?.privacyClass, .personal)
        XCTAssertFalse(plainModel.requests.last?.system?.contains(DeliverablePromptAssembler.clinicalRule) ?? true)
    }

    // (5) A refused order reloads the lists, so the screen shows what is stored now.
    func testARefusedOrderReloadsTheLists() async throws {
        let store = FakeDeliverableStore()
        try await store.installBuiltInTemplates(BuiltInTemplates.all)
        let mine = try await store.createUserTemplate(clinicDraft())
        var changes = 0
        let library = TemplateLibraryViewModel(store: store, recipesUsing: { _ in [] }, didChange: { changes += 1 })
        await library.load()

        // Another screen added a template meanwhile: this list is stale, so its order is refused.
        _ = try await store.createUserTemplate(
            TemplateDraft(
                name: "Referral letter", category: .deliverable, instructions: "Synthetic.",
                makesClinicalDocuments: false))
        await library.moveUp(mine)

        XCTAssertEqual(library.actionError, "The order could not be saved. Nothing changed.")
        XCTAssertEqual(library.documents.last?.name, "Referral letter", "the lists were read again")
        XCTAssertEqual(changes, 0, "nothing changed, so the Transforms tab is not told")
    }
}
