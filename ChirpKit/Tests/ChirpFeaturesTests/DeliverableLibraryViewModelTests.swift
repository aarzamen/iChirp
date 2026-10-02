import ChirpCore
import Foundation
import XCTest

@testable import ChirpFeatures

@MainActor
final class DeliverableLibraryViewModelTests: XCTestCase {
    private func makeDeliverable(_ harness: DeliverableHarness) async throws -> Deliverable {
        let events = try await harness.run(BuiltInTemplates.soapNote, model: Destination.onDevice.makeModel())
        guard case .completed(let deliverable) = events.last else {
            XCTFail("no deliverable")
            throw FakeError(message: "no deliverable")
        }
        return deliverable
    }

    func testListsTemplatesByCategoryAndRecentDocuments() async throws {
        let harness = try await DeliverableHarness(privacy: .personal)
        let library = DeliverableLibraryViewModel(store: harness.deliverables)
        await library.load()
        XCTAssertTrue(library.hasLoaded)
        XCTAssertEqual(
            library.documentTemplates.map(\.name), ["Summary", "Meeting notes", "Action items", "Agenda", "SOAP note"])
        XCTAssertEqual(library.transformTemplates.map(\.name), ["Polish", "Distill", "Decide", "Brief"])
        XCTAssertTrue(library.recent.isEmpty)

        let deliverable = try await makeDeliverable(harness)
        await library.load()
        XCTAssertEqual(library.recent.map(\.id), [deliverable.id])
        XCTAssertEqual(library.recent.first?.privacyClass, .clinical, "a SOAP note is clinical")
    }

    func testDocumentShowsItsProvenanceAndSavesOnlyTheText() async throws {
        let harness = try await DeliverableHarness(privacy: .personal)
        let deliverable = try await makeDeliverable(harness)
        let transcriptBefore = await harness.transcripts.row(harness.transcript.id)

        let document = DeliverableDocumentViewModel(id: deliverable.id, store: harness.deliverables)
        await document.load()
        XCTAssertEqual(document.deliverable?.title, "SOAP note")
        XCTAssertEqual(document.templateVersionNumber, 1)
        XCTAssertEqual(document.draft, "Generated document.")
        XCTAssertFalse(document.hasUnsavedChanges)

        document.draft = "Edited synthetic note."
        XCTAssertTrue(document.hasUnsavedChanges)
        let saved = await document.save()
        XCTAssertTrue(saved)
        XCTAssertFalse(document.hasUnsavedChanges)
        let stored = try await harness.deliverables.fetchDeliverable(id: deliverable.id)
        XCTAssertEqual(stored?.text, "Edited synthetic note.")
        XCTAssertNotNil(stored?.editedAt)
        XCTAssertEqual(stored?.privacyClass, .clinical)
        let transcriptAfter = await harness.transcripts.row(harness.transcript.id)
        XCTAssertEqual(transcriptAfter, transcriptBefore, "editing a document never touches the transcript")
    }

    func testDocumentFromARunStartsWithItsTextAndCanBeDeleted() async throws {
        let harness = try await DeliverableHarness(privacy: .personal)
        let deliverable = try await makeDeliverable(harness)
        let document = DeliverableDocumentViewModel(deliverable: deliverable, store: harness.deliverables)
        XCTAssertEqual(document.draft, deliverable.text)
        try await document.delete()
        XCTAssertTrue(document.isDeleted)
        let gone = try await harness.deliverables.fetchDeliverable(id: deliverable.id)
        XCTAssertNil(gone)
        let transcript = await harness.transcripts.row(harness.transcript.id)
        XCTAssertNotNil(transcript, "the transcript stays")
    }

    // MARK: - Plan 026: your own templates

    private func clinicSOAP(_ harness: DeliverableHarness, _ instructions: String = "Headings A.") async throws
        -> PromptTemplate
    {
        try await harness.deliverables.createUserTemplate(
            TemplateDraft(
                name: "Clinic SOAP", category: .deliverable, instructions: instructions, makesClinicalDocuments: true))
    }

    private func run(_ template: PromptTemplate, _ harness: DeliverableHarness) async throws -> Deliverable {
        var last: DeliverableRunEvent?
        for try await event in harness.service.generate(
            templateID: template.id, transcriptionID: harness.transcript.id, userNotes: nil,
            model: Destination.onDevice.makeModel(), override: nil)
        {
            last = event
        }
        guard case .completed(let deliverable) = last else { throw FakeError(message: "no deliverable") }
        return deliverable
    }

    func testHiddenTemplatesLeaveThePickersButNotTheLibrary() async throws {
        let harness = try await DeliverableHarness(privacy: .personal)
        let mine = try await clinicSOAP(harness)
        try await harness.deliverables.setTemplateVisible(id: BuiltInTemplates.agenda.id, isVisible: false)
        try await harness.deliverables.setTemplateVisible(id: mine.id, isVisible: false)
        try await harness.deliverables.setTemplateVisible(id: BuiltInTemplates.brief.id, isVisible: false)
        let library = DeliverableLibraryViewModel(store: harness.deliverables)
        await library.load()

        XCTAssertEqual(
            library.documentTemplates.map(\.name),
            ["Summary", "Meeting notes", "Action items", "Agenda", "SOAP note", "Clinic SOAP"],
            "every template stays for recipes, Create's validation, Jev and the SOAP hand-off")
        XCTAssertEqual(library.transformTemplates.count, 4)
        XCTAssertEqual(
            library.visibleDocumentTemplates.map(\.name), ["Summary", "Meeting notes", "Action items", "SOAP note"])
        XCTAssertEqual(library.visibleRewriteTemplates.map(\.name), ["Polish", "Distill", "Decide"])
        XCTAssertEqual(library.hiddenTemplateCount, 3)

        XCTAssertEqual(
            library.pickerTemplates(.deliverable, keeping: nil).map(\.name),
            library.visibleDocumentTemplates.map(\.name))
        XCTAssertEqual(
            library.pickerTemplates(.deliverable, keeping: mine.id).map(\.name),
            ["Summary", "Meeting notes", "Action items", "SOAP note", "Clinic SOAP"],
            "a selected hidden template stays choosable, in its place")
        XCTAssertEqual(
            library.pickerTemplates(.transform, keeping: mine.id).map(\.name), ["Polish", "Distill", "Decide"],
            "kept only in its own section")
    }

    func testADocumentSaysWhatMadeItAfterARenameAnEditAndADelete() async throws {
        let harness = try await DeliverableHarness(privacy: .personal)
        let mine = try await clinicSOAP(harness)
        _ = try await harness.deliverables.updateUserTemplate(
            id: mine.id,
            with: TemplateDraft(
                name: "Clinic SOAP", category: .deliverable, instructions: "Headings B.", makesClinicalDocuments: true))
        let edited = try await harness.deliverables.fetchTemplate(id: mine.id)
        let made = try await run(try XCTUnwrap(edited), harness)
        let document = DeliverableDocumentViewModel(id: made.id, store: harness.deliverables)

        await document.load()
        XCTAssertEqual(document.provenance?.made, "Clinic SOAP · version 2")
        XCTAssertEqual(document.provenance?.changes, [])
        XCTAssertNil(document.provenance?.now, "nothing changed since")
        XCTAssertEqual(made.privacyClass, .clinical, "the switch raised the personal item's document")

        _ = try await harness.deliverables.updateUserTemplate(
            id: mine.id,
            with: TemplateDraft(
                name: "Clinic SOAP", category: .deliverable, instructions: "Headings C.", makesClinicalDocuments: true))
        await document.load()
        XCTAssertEqual(document.provenance?.made, "Clinic SOAP · version 2")
        XCTAssertEqual(document.provenance?.changes, ["Edited since: now version 3."])

        _ = try await harness.deliverables.updateUserTemplate(
            id: mine.id,
            with: TemplateDraft(
                name: "SOAP (clinic)", category: .deliverable, instructions: "Headings C.",
                makesClinicalDocuments: true))
        await document.load()
        XCTAssertEqual(document.provenance?.made, "Clinic SOAP · version 2", "the title snapshot stays")
        XCTAssertEqual(document.provenance?.changes, ["Now called “SOAP (clinic)”.", "Edited since: now version 3."])
        XCTAssertEqual(document.provenance?.now, "Now called “SOAP (clinic)”. Edited since: now version 3.")

        try await harness.deliverables.deleteUserTemplate(id: mine.id)
        await document.load()
        XCTAssertEqual(document.provenance?.made, "Clinic SOAP · version 2")
        XCTAssertEqual(document.provenance?.changes, ["Deleted. Restore it in Templates to use it again."])
        XCTAssertTrue(document.provenance?.isTemplateDeleted ?? false)
        XCTAssertEqual(document.deliverable?.title, "Clinic SOAP")
        XCTAssertEqual(document.templateVersionNumber, 2)
    }

    func testABuiltInsAppUpdateIsNamedAsSuch() {
        let template = PromptTemplate(
            name: "Summary", category: .deliverable, isBuiltIn: true, activeVersionID: UUID())
        let used = PromptVersion(promptID: template.id, versionNumber: 1, content: "a", origin: .builtIn)
        let active = PromptVersion(promptID: template.id, versionNumber: 2, content: "b", origin: .systemUpdate)
        let document = Deliverable(
            transcriptionID: UUID(), promptID: template.id, promptVersionID: used.id, title: "Summary",
            engineID: "fake", provider: "Fake", model: nil, locality: .onDevice, text: "x", privacyClass: .personal)
        let provenance = DocumentTemplateProvenance.of(
            document: document, template: template, versionUsed: used, activeVersion: active)
        XCTAssertEqual(provenance?.changes, ["Updated by the app since: now version 2."])
        XCTAssertNil(
            DocumentTemplateProvenance.of(
                document: Deliverable(
                    transcriptionID: UUID(), promptID: nil, promptVersionID: nil, title: "Answer", engineID: "fake",
                    provider: "Fake", model: nil, locality: .onDevice, text: "x", privacyClass: .personal),
                template: nil, versionUsed: nil, activeVersion: nil),
            "an Ask answer has no template")
    }

    func testInstructionsUsedAreTheDocumentsVersion() async throws {
        let harness = try await DeliverableHarness(privacy: .personal)
        let mine = try await clinicSOAP(harness, "Headings A.")
        let made = try await run(mine, harness)
        _ = try await harness.deliverables.updateUserTemplate(
            id: mine.id,
            with: TemplateDraft(
                name: "Clinic SOAP", category: .deliverable, instructions: "Headings B.", makesClinicalDocuments: true))
        try await harness.deliverables.deleteUserTemplate(id: mine.id)

        let document = DeliverableDocumentViewModel(id: made.id, store: harness.deliverables)
        await document.load()
        let used = await document.loadInstructionsUsed()
        XCTAssertEqual(used?.content, "Headings A.")
        XCTAssertEqual(used?.versionNumber, 1)
        XCTAssertTrue(document.provenance?.canShowInstructions ?? false)
    }
}

@MainActor
final class AskSessionViewModelTests: XCTestCase {
    func testQuestionIsAnsweredWithItsRoute() async throws {
        let harness = try await DeliverableHarness(privacy: .personal)
        let session = AskSessionViewModel(service: harness.service, transcriptionID: harness.transcript.id)
        await session.ask("  When is the meeting?  ", model: Destination.onDevice.makeModel(), choice: .onDevice)
        XCTAssertEqual(session.exchanges.map(\.question), ["When is the meeting?"])
        guard case .answered(let answer) = session.exchanges.first?.run.phase else {
            return XCTFail("\(String(describing: session.exchanges.first?.run.phase))")
        }
        XCTAssertEqual(answer.route.locality, .onDevice)
        XCTAssertFalse(session.isBusy)
        let runs = await harness.deliverables.runs
        XCTAssertEqual(runs.map(\.feature), [.ask])
    }

    func testClinicalQuestionToTheCloudWaitsAndADeclinedQuestionSendsNothing() async throws {
        let harness = try await DeliverableHarness(privacy: .clinical)
        let cloud = Destination.cloud.makeModel()
        let session = AskSessionViewModel(service: harness.service, transcriptionID: harness.transcript.id)
        let choice = LanguageModelChoice(
            source: .provider(UUID()), name: "Claude", locality: .cloud, host: "api.example.com",
            isTrustedForClinical: false)
        await session.ask("What was decided?", model: cloud, choice: choice)
        guard case .needsConfirmation = session.exchanges.last?.run.phase else { return XCTFail("expected a question") }
        XCTAssertTrue(session.isBusy)
        await session.ask("A second question while waiting", model: cloud, choice: choice)
        XCTAssertEqual(session.exchanges.count, 1, "one question at a time")

        session.exchanges.last?.run.declineOverride()
        XCTAssertEqual(session.exchanges.last?.run.phase, .idle, "declined: shown as not sent")
        XCTAssertFalse(session.isBusy)
        XCTAssertTrue(cloud.requests.isEmpty)
        let runs = await harness.deliverables.runs
        XCTAssertTrue(runs.isEmpty)
    }

    /// Review R6b-1: the Ask tab's view is rebuilt on every tab switch; the session (owned by the Transcript screen)
    /// keeps the model the person picked and a half-typed question, so a cloud default never comes back unasked.
    func testTheSessionKeepsTheChosenModelAndTheUnsentQuestion() async throws {
        let harness = try await DeliverableHarness(privacy: .personal)
        let session = AskSessionViewModel(service: harness.service, transcriptionID: harness.transcript.id)
        let cloud = LanguageModelChoice(
            source: .provider(UUID()), name: "Claude", locality: .cloud, host: "api.example.com",
            isTrustedForClinical: false)
        XCTAssertNil(session.choice, "no pick yet: the view shows the Settings default")
        XCTAssertEqual(session.choice(default: cloud), cloud)

        session.choice = .onDevice
        session.draftQuestion = "What did they agree on"
        // A view made again later reads the same session.
        XCTAssertEqual(session.choice(default: cloud), .onDevice)
        XCTAssertEqual(session.draftQuestion, "What did they agree on")

        await session.ask(session.draftQuestion, model: Destination.onDevice.makeModel(), choice: .onDevice)
        XCTAssertEqual(session.draftQuestion, "", "a sent question leaves the field")
        XCTAssertEqual(session.choice(default: cloud), .onDevice, "the pick stays for the next question")
    }

    func testBlankQuestionIsIgnored() async throws {
        let harness = try await DeliverableHarness(privacy: .personal)
        let model = Destination.onDevice.makeModel()
        let session = AskSessionViewModel(service: harness.service, transcriptionID: harness.transcript.id)
        await session.ask("   ", model: model, choice: .onDevice)
        XCTAssertTrue(session.exchanges.isEmpty)
        XCTAssertTrue(model.requests.isEmpty)
    }
}
