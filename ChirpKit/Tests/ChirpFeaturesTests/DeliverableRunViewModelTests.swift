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

    /// Plan 022 review M1: a Stop while the route is checked stops the run. An allowed route sends and stores nothing;
    /// a clinical route shows no question over the stopped screen, and a late Send sends nothing.
    func testCancelWhileTheRouteIsCheckedSendsNothingAndAsksNothing() async throws {
        for privacy in [PrivacyClass.personal, .clinical] {
            let harness = try await DeliverableHarness(privacy: privacy)
            let model = Destination.cloud.makeModel()
            let viewModel = DeliverableRunViewModel(
                service: harness.service, model: model, transcriptionID: harness.transcript.id,
                request: .template(id: BuiltInTemplates.summary.id, userNotes: nil))
            let hold = await harness.transcripts.holdNext([.fetch])
            let running = Task { await viewModel.start() }
            await hold.entered.wait()
            XCTAssertEqual(viewModel.phase, .checking, "\(privacy)")
            viewModel.cancel()
            XCTAssertEqual(viewModel.phase, .failed(DeliverableRunViewModel.stoppedMessage), "\(privacy)")
            hold.release.fire()
            await running.value

            XCTAssertEqual(viewModel.phase, .failed(DeliverableRunViewModel.stoppedMessage), "no question: \(privacy)")
            await viewModel.confirmOverride()
            XCTAssertTrue(model.requests.isEmpty, "nothing sent: \(privacy)")
            let stored = try await harness.deliverables.fetchDeliverables(transcriptionID: harness.transcript.id)
            XCTAssertTrue(stored.isEmpty, "nothing stored: \(privacy)")
            let runs = await harness.deliverables.runs
            XCTAssertTrue(runs.isEmpty, "no ledger row: \(privacy)")
        }
    }

    /// A Stop while the clinical question is up: its Send can no longer send.
    func testCancelWhileTheQuestionIsUpMakesSendANoOp() async throws {
        let harness = try await DeliverableHarness(privacy: .clinical)
        let model = Destination.cloud.makeModel()
        let viewModel = DeliverableRunViewModel(
            service: harness.service, model: model, transcriptionID: harness.transcript.id,
            request: .template(id: BuiltInTemplates.summary.id, userNotes: nil))
        await viewModel.start()
        guard case .needsConfirmation = viewModel.phase else { return XCTFail("\(viewModel.phase)") }
        viewModel.cancel()
        await viewModel.confirmOverride()
        XCTAssertTrue(model.requests.isEmpty)
        XCTAssertEqual(viewModel.phase, .failed(DeliverableRunViewModel.stoppedMessage))
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
