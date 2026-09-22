import ChirpCore
import Foundation
import XCTest

@testable import ChirpFeatures

@MainActor
final class DeliverableRunViewModelTests: XCTestCase {
    func testAllowedRunStreamsAndCompletes() async throws {
        let harness = try await DeliverableHarness(privacy: .personal)
        let model = Destination.cloud.makeModel()
        let viewModel = DeliverableRunViewModel(
            service: harness.service, model: model, transcriptionID: harness.transcript.id,
            request: .template(id: BuiltInTemplates.summary.id, userNotes: nil))
        await viewModel.start()
        guard case .completed(let deliverable) = viewModel.phase else { return XCTFail("\(viewModel.phase)") }
        XCTAssertEqual(viewModel.text, deliverable.text)
        XCTAssertEqual(viewModel.route?.locality, .cloud)
    }

    func testClinicalCloudRunWaitsForConfirmationAndSendsNothingUntilThen() async throws {
        let harness = try await DeliverableHarness(privacy: .clinical)
        let model = Destination.cloud.makeModel()
        let viewModel = DeliverableRunViewModel(
            service: harness.service, model: model, transcriptionID: harness.transcript.id,
            request: .template(id: BuiltInTemplates.summary.id, userNotes: nil))
        await viewModel.start()
        guard case .needsConfirmation(let request) = viewModel.phase else { return XCTFail("\(viewModel.phase)") }
        XCTAssertEqual(request.title, "Send this clinical transcript to Claude?")
        XCTAssertTrue(model.requests.isEmpty)

        await viewModel.confirmOverride()
        guard case .completed = viewModel.phase else { return XCTFail("\(viewModel.phase)") }
        XCTAssertTrue(model.everythingReceived.contains(DeliverableHarness.marker))
        let runs = await harness.deliverables.runs
        XCTAssertEqual(runs.map(\.privacyOverride), [true])
    }

    func testDecliningSendsNothing() async throws {
        let harness = try await DeliverableHarness(privacy: .clinical)
        let model = Destination.untrustedLAN.makeModel()
        let viewModel = DeliverableRunViewModel(
            service: harness.service, model: model, transcriptionID: harness.transcript.id,
            request: .ask(question: "When?"))
        await viewModel.start()
        viewModel.declineOverride()
        XCTAssertEqual(viewModel.phase, .idle)
        XCTAssertTrue(model.requests.isEmpty)
        let runs = await harness.deliverables.runs
        XCTAssertTrue(runs.isEmpty, "routing alone writes no ledger row")
    }

    func testFailureIsASentence() async throws {
        let harness = try await DeliverableHarness(privacy: .personal)
        let model = Destination.onDevice.makeModel()
        model.setAvailability(.unavailable(.appleIntelligenceNotEnabled))
        let viewModel = DeliverableRunViewModel(
            service: harness.service, model: model, transcriptionID: harness.transcript.id,
            request: .template(id: BuiltInTemplates.summary.id, userNotes: nil))
        await viewModel.start()
        XCTAssertEqual(viewModel.phase, .failed(LanguageModelUnavailableReason.appleIntelligenceNotEnabled.message))
    }
}
