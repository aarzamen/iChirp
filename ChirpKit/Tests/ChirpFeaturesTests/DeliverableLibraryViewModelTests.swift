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

    func testBlankQuestionIsIgnored() async throws {
        let harness = try await DeliverableHarness(privacy: .personal)
        let model = Destination.onDevice.makeModel()
        let session = AskSessionViewModel(service: harness.service, transcriptionID: harness.transcript.id)
        await session.ask("   ", model: model, choice: .onDevice)
        XCTAssertTrue(session.exchanges.isEmpty)
        XCTAssertTrue(model.requests.isEmpty)
    }
}
