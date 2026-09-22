import ChirpCore
import ChirpText
import Foundation
import XCTest

@testable import ChirpFeatures

final class DeliverableServiceTests: XCTestCase {
    func testDeliverableRecordsTemplateVersionEngineAndNotesAndLeavesTheTranscriptAlone() async throws {
        let harness = try await DeliverableHarness(privacy: .personal)
        let model = Destination.trustedLAN.makeModel()
        let before = await harness.transcripts.row(harness.transcript.id)

        let events = try await harness.run(BuiltInTemplates.meetingNotes, model: model, notes: "Bring the survey map.")
        guard case .completed(let deliverable) = events.last else { return XCTFail("no deliverable") }

        let fetched = try await harness.deliverables.fetchTemplate(id: BuiltInTemplates.meetingNotes.id)
        let template = try XCTUnwrap(fetched)
        XCTAssertEqual(deliverable.promptID, template.id)
        XCTAssertEqual(deliverable.promptVersionID, template.activeVersionID)
        XCTAssertEqual(deliverable.title, "Meeting notes")
        XCTAssertEqual(deliverable.engineID, "http.ollama")
        XCTAssertEqual(deliverable.locality, .localNetwork)
        XCTAssertEqual(deliverable.model, "fake-1")
        XCTAssertEqual(deliverable.text, "Generated document.")
        XCTAssertEqual(deliverable.userNotes, "Bring the survey map.")
        XCTAssertTrue(model.everythingReceived.contains("Bring the survey map."))

        let after = await harness.transcripts.row(harness.transcript.id)
        XCTAssertEqual(after, before, "generated text never touches the transcript")

        let runs = await harness.deliverables.runs
        let run = try XCTUnwrap(runs.first)
        XCTAssertEqual(run.deliverableID, deliverable.id)
        XCTAssertEqual(run.promptVersionID, template.activeVersionID)
        XCTAssertEqual(run.promptTokens, 10)
        XCTAssertEqual(run.completionTokens, 5)
        XCTAssertEqual(run.callCount, 1)
        XCTAssertEqual(run.outputCharacters, "Generated document.".count)
        for field in stringFields(of: run) {
            XCTAssertFalse(field.contains("survey map"), "notes in the ledger")
        }
    }

    func testStreamsTheFinalTextAfterTheWritingStep() async throws {
        let harness = try await DeliverableHarness(privacy: .general)
        let events = try await harness.run(model: Destination.onDevice.makeModel())
        let writing = try XCTUnwrap(events.firstIndex(of: .step(.writing)))
        let deltas = events[writing...].compactMap { if case .text(let text) = $0 { text } else { nil } }
        XCTAssertEqual(deltas.joined(), "Generated document.")
    }

    func testUnavailableModelSendsNothing() async throws {
        let harness = try await DeliverableHarness(privacy: .clinical)
        let apple = Destination.onDevice.makeModel()
        apple.setAvailability(.unavailable(.appleIntelligenceNotEnabled))
        do {
            _ = try await harness.run(model: apple)
            XCTFail("expected modelUnavailable")
        } catch {
            XCTAssertEqual(error as? DeliverableError, .modelUnavailable(.appleIntelligenceNotEnabled))
        }
        XCTAssertTrue(apple.requests.isEmpty)
        let runs = await harness.deliverables.runs
        XCTAssertEqual(runs.map(\.status), [.failed])
        XCTAssertEqual(runs.first?.errorType, "model_unavailable")
    }

    func testModelErrorFailsTheRunWithAContentFreeLedgerEntry() async throws {
        let harness = try await DeliverableHarness(privacy: .personal)
        let model = Destination.cloud.makeModel()
        model.script([.error(.providerError("echo: \(DeliverableHarness.marker)"))])
        do {
            _ = try await harness.run(model: model)
            XCTFail("expected the provider error")
        } catch {
            guard case .providerError = error as? LanguageModelError else { return XCTFail("\(error)") }
        }
        let runs = await harness.deliverables.runs
        XCTAssertEqual(runs.first?.status, .failed)
        XCTAssertEqual(runs.first?.errorType, "provider_error")
        let stored = await harness.deliverables.deliverables
        XCTAssertTrue(stored.isEmpty)
    }

    func testContextTooLongReplansIntoPartsInsteadOfTruncating() async throws {
        let lines = (1...150).map { "Speaker 1: synthetic line LINE\($0)END about the heron survey." }
        let harness = try await DeliverableHarness(privacy: .clinical, text: lines.joined(separator: "\n"))
        // Claims a big window, then rejects the single pass: the planner halves the window and splits.
        let model = RecordingLanguageModel(locality: .onDevice, contextTokens: 8_192)
        model.script([.error(.contextTooLong)])
        let events = try await harness.run(model: model)
        guard case .completed = events.last else { return XCTFail("expected a deliverable") }
        let mapPrompts = model.requests.filter { $0.prompt.contains("<transcript_part") }.map(\.prompt)
        XCTAssertGreaterThan(mapPrompts.count, 1)
        XCTAssertFalse(model.requests[0].prompt.contains("<transcript_part"), "the first attempt was one call")
        for line in 1...150 {
            XCTAssertEqual(mapPrompts.filter { $0.contains("LINE\(line)END") }.count, 1, "line \(line)")
        }
        let runs = await harness.deliverables.runs
        XCTAssertEqual(runs.first?.callCount, model.requests.count)
    }

    func testCancelledRunStoresNothingAndRecordsCancelled() async throws {
        let harness = try await DeliverableHarness(privacy: .personal)
        let model = Destination.onDevice.makeModel()
        let entered = Signal()
        let release = Signal()
        model.onEachCall { _ in
            entered.fire()
            await release.wait()
        }
        let run = Task { try await harness.run(model: model) }
        await entered.wait()
        run.cancel()
        release.fire()
        // A cancelled consumer ends the stream; the run behind it is cancelled too.
        let events = (try? await run.value) ?? []
        XCTAssertFalse(events.contains { if case .completed = $0 { true } else { false } })
        // The ledger row is written by the cancelled run itself; wait for it without sleeping.
        var runs = await harness.deliverables.runs
        for _ in 0..<10_000 where runs.isEmpty {
            await Task.yield()
            runs = await harness.deliverables.runs
        }
        XCTAssertEqual(runs.map(\.status), [.cancelled])
        let stored = await harness.deliverables.deliverables
        XCTAssertTrue(stored.isEmpty)
    }

    func testSetPrivacyClassRaisesDeliverablesButNeverLowersThem() async throws {
        let harness = try await DeliverableHarness(privacy: .personal)
        _ = try await harness.run(model: Destination.onDevice.makeModel())
        _ = try await harness.run(BuiltInTemplates.soapNote, model: Destination.onDevice.makeModel())

        try await harness.service.setPrivacyClass(.clinical, transcriptionID: harness.transcript.id)
        var classes = await harness.deliverables.deliverables.values.map(\.privacyClass)
        XCTAssertEqual(Set(classes), [.clinical])
        let row = await harness.transcripts.row(harness.transcript.id)
        XCTAssertEqual(row?.privacyClass, .clinical)

        try await harness.service.setPrivacyClass(.general, transcriptionID: harness.transcript.id)
        classes = await harness.deliverables.deliverables.values.map(\.privacyClass)
        XCTAssertEqual(Set(classes), [.clinical], "lowering a transcript never lowers its documents")
    }

    func testAskReturnsOnlyCitationsThatPointAtRealSegments() async throws {
        var row = Transcription(fileName: "synthetic.m4a", status: .completed, privacyClass: .personal)
        row.transcriptSegments = [
            TranscriptSegmentRecord(
                startMs: 12_500, endMs: 15_000, speakerId: "S1", speakerLabel: "Speaker 1",
                text: "The review is on Thursday.", wordRange: TranscriptSegmentWordRange(startIndex: 0, endIndexExclusive: 5)),
            TranscriptSegmentRecord(
                startMs: 246_000, endMs: 250_000, speakerId: "S2", speakerLabel: "Speaker 2",
                text: "Bring the heron map.", wordRange: TranscriptSegmentWordRange(startIndex: 5, endIndexExclusive: 9)),
        ]
        row.speakers = [SpeakerInfo(id: "S1", label: "Dana"), SpeakerInfo(id: "S2", label: "Speaker 2")]
        let transcripts = FakeStore(rows: [row])
        let service = DeliverableService(
            transcripts: transcripts, deliverables: FakeDeliverableStore(), routingPolicy: { PrivacyRoutingPolicy() })
        let model = Destination.onDevice.makeModel()
        model.script([.text("Thursday [00:12], bring the map [04:06]; also [09:59].")])

        var answer: AskAnswer?
        for try await event in service.ask(question: "When?", transcriptionID: row.id, model: model) {
            if case .answered(let value) = event { answer = value }
        }
        XCTAssertEqual(
            answer?.citations,
            [TranscriptCitation(label: "00:12", startMs: 12_500), TranscriptCitation(label: "04:06", startMs: 246_000)])
        XCTAssertTrue(model.everythingReceived.contains("[00:12] Dana: The review is on Thursday."))
        XCTAssertTrue(model.everythingReceived.contains("[04:06] Speaker 2: Bring the heron map."))
    }

    func testEmptyTranscriptSendsNothing() async throws {
        let harness = try await DeliverableHarness(privacy: .personal, text: "   ")
        let model = Destination.onDevice.makeModel()
        do {
            _ = try await harness.run(model: model)
            XCTFail("expected emptyTranscript")
        } catch {
            XCTAssertEqual(error as? DeliverableError, .emptyTranscript)
        }
        XCTAssertTrue(model.requests.isEmpty)
    }
}
