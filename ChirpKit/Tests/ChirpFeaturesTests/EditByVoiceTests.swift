import ChirpCore
import Foundation
import XCTest

@testable import ChirpFeatures

/// Plan 022 Step 4: Edit by voice. An edit is stored as the document's next version (the text it had is kept), routes
/// like any run on the item's effective class, and its instruction never reaches the ledger. Everything is synthetic.
@MainActor
final class EditByVoiceTests: XCTestCase {
    static let instruction = "Make it shorter SYNTHETIC-WREN-2291"

    /// A transcript and a Summary made from it on the on-device model ("Generated document.").
    private func makeDocument(
        privacy: PrivacyClass = .personal, template: BuiltInPromptTemplate = BuiltInTemplates.summary
    ) async throws -> (DeliverableHarness, Deliverable) {
        let harness = try await DeliverableHarness(privacy: privacy)
        let events = try await harness.run(template, model: RecordingLanguageModel(locality: .onDevice))
        guard case .completed(let document)? = events.last else {
            throw FakeError(message: "no document was generated")
        }
        return (harness, document)
    }

    private func edit(
        _ harness: DeliverableHarness, _ document: Deliverable, model: RecordingLanguageModel,
        instruction: String = instruction, override: PrivacyOverride? = nil
    ) async throws -> [DeliverableRunEvent] {
        var events: [DeliverableRunEvent] = []
        for try await event in harness.service.edit(
            deliverableID: document.id, instruction: instruction, spoken: true, model: model, override: override)
        {
            events.append(event)
        }
        return events
    }

    func testAnEditIsTheNextVersionAndTheOriginalIsKept() async throws {
        let (harness, document) = try await makeDocument()
        let model = RecordingLanguageModel(locality: .onDevice)
        model.script([.text("A shorter synthetic summary.")])
        let events = try await edit(harness, document, model: model)
        guard case .completed(let edited)? = events.last else { return XCTFail("\(events)") }
        XCTAssertEqual(edited.id, document.id)
        XCTAssertEqual(edited.text, "A shorter synthetic summary.")

        let versions = try await harness.deliverables.fetchDeliverableVersions(deliverableID: document.id)
        XCTAssertEqual(versions.map(\.origin), [.original, .spokenEdit])
        XCTAssertEqual(versions[0].text, "Generated document.", "the earlier text is a version, not overwritten")
        XCTAssertEqual(versions[1].instruction, Self.instruction)
        let transcript = try await harness.transcripts.fetch(id: harness.transcript.id)
        XCTAssertEqual(transcript?.rawTranscript, harness.transcript.rawTranscript, "the transcript is never touched")

        // A second edit appends again; nothing earlier changes.
        model.script([.text("Shortest.")])
        _ = try await edit(harness, document, model: model, instruction: "Even shorter")
        let after = try await harness.deliverables.fetchDeliverableVersions(deliverableID: document.id)
        XCTAssertEqual(after.map(\.versionNumber), [1, 2, 3])
        XCTAssertEqual(Array(after.prefix(2)), versions)
    }

    func testTheModelGetsTheDocumentAndTheInstructionTheLedgerNeither() async throws {
        let (harness, document) = try await makeDocument()
        let model = RecordingLanguageModel(locality: .onDevice)
        _ = try await edit(harness, document, model: model)
        XCTAssertTrue(model.everythingReceived.contains("<document>\nGenerated document.\n</document>"))
        XCTAssertTrue(model.everythingReceived.contains("Instruction: \(Self.instruction)"))
        let runs = try await harness.deliverables.fetchRuns(limit: 10)
        let editRun = try XCTUnwrap(runs.first { $0.feature == .edit })
        XCTAssertEqual(editRun.status, .succeeded)
        XCTAssertEqual(editRun.deliverableID, document.id)
        for field in stringFields(of: editRun) {
            XCTAssertFalse(field.contains("SYNTHETIC-WREN"), "the ledger holds no instruction")
            XCTAssertFalse(field.contains("Generated document"), "the ledger holds no text")
        }
    }

    func testAClinicalDocumentAsksBeforeTheCloudAndOnlyTheTokenSends() async throws {
        // A SOAP note (clinical output) from a personal transcript: the transcript's effective class is clinical.
        let (harness, document) = try await makeDocument(template: BuiltInTemplates.soapNote)
        XCTAssertEqual(document.privacyClass, .clinical)
        let cloud = RecordingLanguageModel(locality: .cloud, host: "api.example.com")

        let decision = try await harness.service.routeEdit(deliverableID: document.id, model: cloud)
        guard case .needsOverride(let request) = decision else { return XCTFail("a clinical edit went to the cloud") }
        XCTAssertEqual(request.route.privacyClass, .clinical)
        do {
            _ = try await edit(harness, document, model: cloud)
            XCTFail("sent without the confirmation")
        } catch DeliverableError.privacyOverrideRequired {
        }
        XCTAssertTrue(cloud.requests.isEmpty)
        let untouched = try await harness.deliverables.fetchDeliverableVersions(deliverableID: document.id)
        XCTAssertTrue(untouched.isEmpty, "a refused edit stores nothing")

        let token = try await harness.service.confirmOverride(request)
        let events = try await edit(harness, document, model: cloud, override: token)
        guard case .completed(let edited)? = events.last else { return XCTFail("\(events)") }
        XCTAssertEqual(edited.privacyClass, .clinical)
        XCTAssertEqual(cloud.requests.count, 1)
        let runs = try await harness.deliverables.fetchRuns(limit: 10)
        XCTAssertTrue(runs.contains { $0.feature == .edit && $0.privacyOverride && $0.status == .succeeded })
    }

    func testATrustedMacEditsAClinicalDocumentWithoutAsking() async throws {
        let (harness, document) = try await makeDocument(privacy: .clinical)
        let mac = RecordingLanguageModel(locality: .localNetwork, host: DeliverableHarness.trustedHost)
        let events = try await edit(harness, document, model: mac)
        guard case .completed = events.last else { return XCTFail("\(events)") }
    }

    func testAnEmptyInstructionSendsNothing() async throws {
        let (harness, document) = try await makeDocument()
        let model = RecordingLanguageModel(locality: .onDevice)
        do {
            _ = try await edit(harness, document, model: model, instruction: "   ")
            XCTFail("an empty instruction ran")
        } catch {
            XCTAssertEqual(error as? DeliverableError, .emptyInstruction)
        }
        XCTAssertTrue(model.requests.isEmpty)
    }

    func testADocumentTooLongForOnePassIsRefusedBeforeSending() async throws {
        let harness = try await DeliverableHarness(privacy: .personal)
        let long = Deliverable(
            transcriptionID: harness.transcript.id, promptID: nil, promptVersionID: nil, title: "Long", engineID: "x",
            provider: "x", model: nil, locality: .onDevice,
            text: String(repeating: "Synthetic sentence for a long document. ", count: 400), privacyClass: .personal)
        try await harness.deliverables.insertDeliverable(long)
        let small = RecordingLanguageModel(locality: .onDevice, contextTokens: 1_024)
        do {
            _ = try await edit(harness, long, model: small)
            XCTFail("an over-long document was sent")
        } catch {
            XCTAssertEqual(error as? DeliverableError, .documentTooLongToEdit)
        }
        XCTAssertTrue(small.requests.isEmpty, "nothing was sent, nothing was cut")
        let stored = try await harness.deliverables.fetchDeliverable(id: long.id)
        XCTAssertEqual(stored?.text, long.text)
    }

    func testAFailedEditLeavesTheDocumentAsItWas() async throws {
        let (harness, document) = try await makeDocument()
        let model = RecordingLanguageModel(locality: .onDevice)
        model.script([.error(.streamingError("synthetic failure"))])
        do {
            _ = try await edit(harness, document, model: model)
            XCTFail("a failed edit succeeded")
        } catch {}
        let stored = try await harness.deliverables.fetchDeliverable(id: document.id)
        XCTAssertEqual(stored?.text, "Generated document.")
        let versions = try await harness.deliverables.fetchDeliverableVersions(deliverableID: document.id)
        XCTAssertTrue(versions.isEmpty)
    }

    func testTheRunViewModelDrivesAnEdit() async throws {
        let (harness, document) = try await makeDocument()
        let model = RecordingLanguageModel(locality: .onDevice)
        model.script([.text("Edited through the view model.")])
        let run = DeliverableRunViewModel(
            service: harness.service, model: model, transcriptionID: document.transcriptionID,
            request: .edit(deliverableID: document.id, instruction: "Tighten it", spoken: false))
        await run.start()
        guard case .completed(let edited) = run.phase else { return XCTFail("\(run.phase)") }
        XCTAssertEqual(edited.text, "Edited through the view model.")
        let versions = try await harness.deliverables.fetchDeliverableVersions(deliverableID: document.id)
        XCTAssertEqual(versions.last?.origin, .typedEdit)
    }

    // MARK: - Versions sheet

    func testRestoreAppendsTheEarlierTextAsTheNewestVersion() async throws {
        let (harness, document) = try await makeDocument()
        let model = RecordingLanguageModel(locality: .onDevice)
        model.script([.text("Version two.")])
        _ = try await edit(harness, document, model: model)
        let versions = DocumentVersionsViewModel(
            deliverableID: document.id, documents: harness.deliverables, store: harness.deliverables)
        await versions.load()
        XCTAssertEqual(versions.currentVersionNumber, 2)
        XCTAssertEqual(versions.newestFirst.map(\.versionNumber), [2, 1])

        let restored = await versions.restore(try XCTUnwrap(versions.versions.first))
        XCTAssertEqual(restored?.text, "Generated document.")
        XCTAssertEqual(versions.versions.map(\.versionNumber), [1, 2, 3])
        XCTAssertEqual(versions.versions.last?.origin, .restore)
        XCTAssertEqual(versions.versions.last?.restoredFrom, 1)
        XCTAssertEqual(versions.currentVersionNumber, 3)
        XCTAssertEqual(versions.versions[1].text, "Version two.", "restoring overwrites nothing")
    }

    // MARK: - The spoken instruction

    func testTheSpokenInstructionIsTheFinalPassAndLeavesNothingBehind() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
            "EditByVoiceTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let capture = FakeCapture()
        let speech = FakeSpeech()
        await speech.setTranscript(text: "um make it shorter", words: [])
        let recorder = SpokenInstructionRecorder(
            capture: capture, speech: speech, scheduler: SpeechJobScheduler(), settings: InMemorySettingsStore(),
            temporaryRoot: folder)
        recorder.start()
        await eventually("listening") { recorder.phase == .listening }
        let text = await recorder.stop()
        XCTAssertEqual(text?.lowercased().contains("make it shorter"), true)
        XCTAssertFalse(text?.lowercased().hasPrefix("um") ?? true, "Clean ran on the final pass")
        XCTAssertEqual(recorder.phase, .idle)
        let options = await speech.transcribedOptions
        XCTAssertEqual(options.map(\.purpose), [.dictation], "the dictation path's final pass")
        let left = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        XCTAssertTrue(left.isEmpty, "the instruction's recording is deleted")
    }

    func testNoSpeechSaysSoAndReturnsNothing() async throws {
        let capture = FakeCapture()
        let speech = FakeSpeech()
        await speech.setTranscript(text: "  ", words: [])
        let recorder = SpokenInstructionRecorder(
            capture: capture, speech: speech, scheduler: SpeechJobScheduler(), settings: InMemorySettingsStore())
        recorder.start()
        await eventually("listening") { recorder.phase == .listening }
        let text = await recorder.stop()
        XCTAssertNil(text)
        XCTAssertEqual(recorder.phase, .failed(SpokenInstructionRecorder.noSpeechMessage))
    }

    func testAMissingModelOrMicrophoneSaysWhy() async throws {
        let speech = FakeSpeech(status: .notDownloaded)
        let recorder = SpokenInstructionRecorder(
            capture: FakeCapture(), speech: speech, scheduler: SpeechJobScheduler(), settings: InMemorySettingsStore())
        recorder.start()
        await eventually("failed") { if case .failed = recorder.phase { return true } else { return false } }
        XCTAssertEqual(recorder.phase, .failed(FileTranscriptionPipeline.modelMissingMessage))

        let capture = FakeCapture()
        capture.setPermission(.denied)
        let denied = SpokenInstructionRecorder(
            capture: capture, speech: FakeSpeech(), scheduler: SpeechJobScheduler(), settings: InMemorySettingsStore())
        denied.start()
        await eventually("failed") { if case .failed = denied.phase { return true } else { return false } }
        XCTAssertEqual(capture.starts, 0, "nothing records without permission")
    }
}
