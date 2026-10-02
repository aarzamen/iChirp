import ChirpCore
import ChirpFeatures
import ChirpStore
import Foundation
import Synchronization
import XCTest

@testable import iChirp

/// Plan 026 Steps 7–9: the template screens' words, and the whole life of a template of your own in a real database
/// (GRDB file, the real `DeliverableService`, an on-device recording model): make it from SOAP note, run it, edit it,
/// hide it, delete it, restore it — with the document, the pickers and a recipe following along. Every text is
/// synthetic; nothing touches the network.
@MainActor
final class TemplateLibraryAppTests: XCTestCase {
    // MARK: - Words

    func testTemplateWords() {
        let soap = PromptTemplate(
            name: "SOAP note", category: .deliverable, isBuiltIn: true, canonicalKey: "soap-note",
            outputPrivacyClass: .clinical, activeVersionID: UUID())
        var mine = PromptTemplate(
            name: "Clinic SOAP", category: .deliverable, outputPrivacyClass: .clinical, activeVersionID: UUID())
        XCTAssertEqual(TemplateWords.rowSubtitle(soap), "Subjective, objective, assessment and plan")
        XCTAssertEqual(TemplateWords.rowSubtitle(mine), "Your template")
        XCTAssertEqual(TemplateWords.accessibilityLabel(mine), "Clinic SOAP, your template, clinical")
        mine.isVisible = false
        XCTAssertEqual(TemplateWords.accessibilityLabel(mine), "Clinic SOAP, your template, clinical, hidden")
        XCTAssertEqual(TemplateWords.spokenRow(mine), "Clinic SOAP, your template, clinical, hidden")
        XCTAssertEqual(
            TemplateWords.spokenRow(soap), "SOAP note, built-in, clinical. Subjective, objective, assessment and plan")
        XCTAssertEqual(TemplateWords.hiddenCaption, "Hidden")
        XCTAssertEqual(TemplateWords.nameCounter(12), "12 of 40")
        XCTAssertEqual(TemplateWords.instructionsCounter(1_240), "1,240 of 4,000 characters")
        XCTAssertEqual(TemplateWords.hiddenNote(1), "1 hidden template. Show it in Templates.")
        XCTAssertEqual(TemplateWords.hiddenNote(3), "3 hidden templates. Show them in Templates.")
        XCTAssertEqual(TemplateWords.menuLabel(soap), "Duplicate, hide or move SOAP note")
        XCTAssertEqual(TemplateWords.menuLabel(mine), "Edit, hide, move or delete Clinic SOAP")
        XCTAssertEqual(TemplateWords.sectionTitle(.deliverable), "Documents")
        XCTAssertEqual(TemplateWords.sectionTitle(.transform), "Rewrites")
        XCTAssertEqual(TemplateWords.instructionsSubtitle(name: "Clinic SOAP", version: 2), "Clinic SOAP · version 2")
        // Every row action has a title and an icon.
        for action in TemplateAction.allCases {
            XCTAssertFalse(TemplateWords.actionTitle(action).isEmpty)
            XCTAssertFalse(TemplateWords.actionImage(action).isEmpty)
        }
        // A built-in opens in the editor only as a copy.
        XCTAssertEqual(TemplateEditorRequest.edit(soap).mode, .new(startingFrom: soap))
        XCTAssertEqual(TemplateEditorRequest.edit(mine).mode, .edit(mine))
    }

    // MARK: - The whole life of a template, real database

    func testTheLifeOfAUserTemplateInARealDatabase() async throws {
        let harness = try await TemplatesHarness()
        let store = harness.deliverableStore
        let all = try await store.fetchTemplates()
        let soap = try XCTUnwrap(all.first { $0.canonicalKey == "soap-note" })

        // Start from SOAP note, rename, save.
        let editor = TemplateEditorViewModel(mode: .new(startingFrom: soap), store: store)
        await editor.load()
        XCTAssertEqual(editor.name, "SOAP note copy")
        XCTAssertTrue(editor.makesClinicalDocuments)
        editor.name = "Clinic SOAP"
        editor.instructions = "Use the headings Visit, Findings, Plan. Keep every dose exact."
        let saved = await editor.save()
        let clinic = try XCTUnwrap(saved)

        // Run it on a personal item: a clinical document named "Clinic SOAP", version 1, with the app rules.
        let document = try await harness.run(clinic)
        XCTAssertEqual(document.title, "Clinic SOAP")
        XCTAssertEqual(document.privacyClass, .clinical)
        let sent = try XCTUnwrap(harness.model.lastRequest)
        XCTAssertTrue(sent.system?.contains("This is a clinical draft for the clinician to review and sign.") ?? false)
        XCTAssertTrue(sent.prompt.hasPrefix("Use the headings Visit, Findings, Plan."))
        let details = DeliverableDocumentViewModel(id: document.id, store: store)
        await details.load()
        XCTAssertEqual(details.templateVersionNumber, 1)
        XCTAssertNil(details.provenance?.now)

        // Edit the text: version 2; the document still names version 1 and says what changed.
        let reopened = TemplateEditorViewModel(mode: .edit(clinic), store: store)
        await reopened.load()
        reopened.instructions = "Use the headings Visit, Findings, Assessment, Plan."
        XCTAssertEqual(reopened.nextVersionNumber, 2)
        _ = await reopened.save()
        await details.load()
        XCTAssertEqual(details.templateVersionNumber, 1)
        XCTAssertEqual(details.provenance?.changes, ["Edited since: now version 2."])
        let used = await details.loadInstructionsUsed()
        XCTAssertEqual(used?.content, "Use the headings Visit, Findings, Plan. Keep every dose exact.")

        // A recipe that makes it.
        let recipe = CreateRecipe(
            name: "Dictate → Clinic SOAP",
            choices: CreateChoices(input: .speak, output: .document, templateID: clinic.id, isClinical: true),
            templateName: "Clinic SOAP")
        let library = TemplateLibraryViewModel(
            store: store, recipesUsing: { id in recipe.uses(templateID: id) ? [recipe.name] : [] }, didChange: {})
        let transforms = DeliverableLibraryViewModel(store: store)

        // Hide: out of the pickers, still runnable, the recipe still passes.
        await library.load()
        let listed = try XCTUnwrap(library.documents.first { $0.id == clinic.id })
        await library.setVisible(listed, false)
        await transforms.load()
        XCTAssertFalse(transforms.visibleDocumentTemplates.contains { $0.id == clinic.id })
        XCTAssertTrue(transforms.documentTemplates.contains { $0.id == clinic.id })
        XCTAssertNil(harness.check(recipe, transforms))
        _ = try await harness.run(clinic)

        // Delete: the question names the document and the recipe; the document says deleted; the recipe blocks.
        let impact = await library.deleteImpact(of: clinic)
        XCTAssertEqual(
            impact.message,
            "The 2 documents made with it stay and still say which template made it. The recipe “Dictate → Clinic "
                + "SOAP” stops working until you restore the template. You can restore it later from Deleted templates."
        )
        await library.delete(clinic)
        await details.load()
        XCTAssertEqual(details.provenance?.changes, ["Deleted. Restore it in Templates to use it again."])
        XCTAssertEqual(details.deliverable?.title, "Clinic SOAP", "the document keeps its name")
        await transforms.load()
        XCTAssertNotNil(harness.check(recipe, transforms))
        do {
            _ = try await harness.run(clinic)
            XCTFail("a deleted template ran")
        } catch {
            XCTAssertEqual(error as? DeliverableError, .templateDeleted)
        }

        // Restore: the recipe runs again.
        let deleted = try XCTUnwrap(library.deleted.first)
        await library.restore(deleted)
        await transforms.load()
        XCTAssertNil(harness.check(recipe, transforms))
    }

    func testTheTransformsListsShowYourTemplatesAndHideHiddenOnes() async throws {
        let harness = try await TemplatesHarness()
        let store = harness.deliverableStore
        let clinic = try await store.createUserTemplate(
            TemplateDraft(
                name: "Clinic SOAP", category: .deliverable, instructions: "Synthetic headings.",
                makesClinicalDocuments: true))
        let plain = try await store.createUserTemplate(
            TemplateDraft(
                name: "Plain words", category: .transform, instructions: "Simpler words.",
                makesClinicalDocuments: false))
        let all = try await store.fetchTemplates()
        let agenda = try XCTUnwrap(all.first { $0.canonicalKey == "agenda" })
        try await store.setTemplateVisible(id: agenda.id, isVisible: false)

        let transforms = DeliverableLibraryViewModel(store: store)
        await transforms.load()
        XCTAssertEqual(
            transforms.visibleDocumentTemplates.map(\.name),
            ["Summary", "Meeting notes", "Action items", "SOAP note", "Clinic SOAP"])
        XCTAssertEqual(
            transforms.visibleRewriteTemplates.map(\.name), ["Polish", "Distill", "Decide", "Brief", "Plain words"])
        XCTAssertEqual(transforms.hiddenTemplateCount, 1)
        XCTAssertEqual(
            TemplateWords.hiddenNote(transforms.hiddenTemplateCount), "1 hidden template. Show it in Templates.")
        // Create's menu keeps a remembered hidden choice in its place.
        XCTAssertTrue(transforms.pickerTemplates(.deliverable, keeping: agenda.id).contains { $0.id == agenda.id })
        XCTAssertFalse(transforms.pickerTemplates(.deliverable, keeping: nil).contains { $0.id == agenda.id })
        _ = (clinic, plain)
    }

    func testDetailsRowsSayWhatMadeTheDocumentAndWhatChangedSince() {
        let document = Deliverable(
            transcriptionID: UUID(), promptID: UUID(), promptVersionID: UUID(), title: "Clinic SOAP",
            engineID: "apple.foundation-models", provider: "Apple on-device model", model: nil, locality: .onDevice,
            text: "Synthetic.", privacyClass: .clinical)
        let unchanged = DeliverableDetailScreen.metadata(document, versionNumber: 2, sourceTitle: "Synthetic visit")
        XCTAssertEqual(unchanged.first { $0.0 == "Template" }?.1, "Clinic SOAP · version 2")
        XCTAssertFalse(unchanged.contains { $0.0 == "Template now" })

        let changed = DocumentTemplateProvenance(
            made: "Clinic SOAP · version 2", changes: ["Now called “SOAP (clinic)”.", "Edited since: now version 3."],
            isTemplateDeleted: false, canShowInstructions: true)
        let rows = DeliverableDetailScreen.metadata(
            document, versionNumber: 2, sourceTitle: "Synthetic visit", provenance: changed)
        let labels = rows.map { $0.0 }
        XCTAssertEqual(Array(labels.prefix(3)), ["From", "Template", "Template now"])
        XCTAssertEqual(
            rows.first { $0.0 == "Template now" }?.1, "Now called “SOAP (clinic)”. Edited since: now version 3.")
    }
}

/// A real GRDB file database with one synthetic personal transcript, the real `DeliverableService` with the built-in
/// templates, and an on-device recording model.
@MainActor
private struct TemplatesHarness {
    let transcriptID: UUID
    let service: DeliverableService
    let deliverableStore: GRDBDeliverableStore
    let model = TemplatesRecordingModel()

    init() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
            "TemplateLibraryAppTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let database = try DatabaseManager(url: folder.appendingPathComponent("test.sqlite"))
        let transcripts = GRDBTranscriptionStore(database: database)
        deliverableStore = GRDBDeliverableStore(database: database)
        var row = Transcription(
            fileName: "synthetic.m4a", durationMs: 60_000, status: .completed, privacyClass: .personal)
        row.rawTranscript = "Synthetic visit: the follow-up moves to Thursday. Take 2.5 mg twice a day."
        try await transcripts.insert(row)
        transcriptID = row.id
        service = DeliverableService(
            transcripts: transcripts, deliverables: deliverableStore,
            routingPolicy: { PrivacyRoutingPolicy(trustedLocalNetworkHosts: []) })
        try await service.installBuiltInTemplates()
    }

    func run(_ template: PromptTemplate) async throws -> Deliverable {
        var last: DeliverableRunEvent?
        for try await event in service.generate(
            templateID: template.id, transcriptionID: transcriptID, userNotes: nil, model: model, override: nil)
        {
            last = event
        }
        guard case .completed(let document) = last else { throw TemplatesHarnessError.noDocument }
        return document
    }

    /// Capture's recipe check with the Transforms library's ids (hidden ones included, deleted ones not).
    func check(_ recipe: CreateRecipe, _ library: DeliverableLibraryViewModel) -> String? {
        CreateRecipeCheck.problem(
            recipe, templateIDs: Set(library.templates.map(\.id)), modelIDs: [], modelProblem: nil,
            voiceProblem: nil, speechModelReady: true)
    }
}

private enum TemplatesHarnessError: Error { case noDocument }

/// An on-device `LanguageModel` that records what it is sent and answers with a short synthetic text.
private final class TemplatesRecordingModel: LanguageModel {
    let descriptor = EngineDescriptor(
        id: "test.onDevice", kind: .language, provider: "Test", displayName: "Synthetic on-device", locality: .onDevice,
        license: "Test")
    let endpointHost: String? = nil
    private let received = Mutex<[GenerationRequest]>([])

    var lastRequest: GenerationRequest? { received.withLock { $0.last } }

    func contextWindowTokens() async -> Int? { 8_192 }

    func generate(_ request: GenerationRequest) -> AsyncThrowingStream<GenerationEvent, Error> {
        received.withLock { $0.append(request) }
        return AsyncThrowingStream { continuation in
            continuation.yield(.text("## Visit\nSynthetic follow-up on Thursday."))
            continuation.yield(.usage(GenerationUsage(model: "synthetic-model")))
            continuation.yield(.finished)
            continuation.finish()
        }
    }
}
