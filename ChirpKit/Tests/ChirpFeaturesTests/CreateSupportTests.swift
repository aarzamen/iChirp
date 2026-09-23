import ChirpCore
import Foundation
import XCTest

@testable import ChirpFeatures

/// Plan 022 Step 2: the two small hooks a Create chain relies on.
@MainActor
final class CreateSupportTests: XCTestCase {
    func testWaitForJobReturnsWhenTheTrackedJobEnds() async {
        let center = TranscriptionJobCenter()
        let id = UUID()
        let hold = Hold()
        center.startTracked(id, title: "Synthetic") {
            hold.entered.fire()
            await hold.release.wait()
            return nil
        }
        await hold.entered.wait()
        XCTAssertTrue(center.isRunning(id))
        let waiter = Task { @MainActor in
            await center.waitForJob(id)
            return center.isRunning(id)
        }
        hold.release.fire()
        let stillRunning = await waiter.value
        XCTAssertFalse(stillRunning, "waitForJob returns only after the job ended")
    }

    func testWaitForJobWithoutAJobReturnsAtOnce() async {
        let center = TranscriptionJobCenter()
        await center.waitForJob(UUID())
    }

    func testTheRunTellsItsChainWhenTheDialogWasAnswered() async throws {
        let harness = try await DeliverableHarness(privacy: .clinical)
        let cloud = RecordingLanguageModel(locality: .cloud, host: "api.example.com")
        var answers = 0

        let declined = DeliverableRunViewModel(
            service: harness.service, model: cloud, transcriptionID: harness.transcript.id,
            request: .template(id: BuiltInTemplates.summary.id, userNotes: nil))
        declined.onAnswered = { answers += 1 }
        await declined.start()
        guard case .needsConfirmation = declined.phase else { return XCTFail("expected the question") }
        XCTAssertEqual(answers, 0, "asking is not answering")
        declined.declineOverride()
        XCTAssertEqual(answers, 1)
        XCTAssertTrue(cloud.requests.isEmpty)

        let sent = DeliverableRunViewModel(
            service: harness.service, model: cloud, transcriptionID: harness.transcript.id,
            request: .template(id: BuiltInTemplates.summary.id, userNotes: nil))
        sent.onAnswered = { answers += 1 }
        await sent.start()
        await sent.confirmOverride()
        XCTAssertEqual(answers, 2)
        guard case .completed = sent.phase else { return XCTFail("Send finished the run: \(sent.phase)") }
    }
}
