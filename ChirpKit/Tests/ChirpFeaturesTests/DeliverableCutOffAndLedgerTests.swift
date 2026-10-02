import ChirpCore
import Foundation
import XCTest

@testable import ChirpFeatures

/// Plan 024 Task 8: a generation the model stopped at its length limit is kept and marked incomplete on every path
/// (reviews R3-1, R4-2); the ledger counts every call that went out (R4-4); a class raised mid-run is the class the
/// document is stored with (R4-11) and the class an edit is sent with (R4-12); Edit by voice edits the draft on screen
/// (R5-9, service side). Everything is synthetic.
@MainActor
final class DeliverableCutOffAndLedgerTests: XCTestCase {
    /// A transcript long enough for several map-reduce parts on a 4K window.
    private func longHarness(privacy: PrivacyClass = .personal) async throws -> DeliverableHarness {
        let lines = (1...400).map { "Speaker one says synthetic line \($0) about the heron survey, dose 2.5 mg." }
        return try await DeliverableHarness(privacy: privacy, text: lines.joined(separator: "\n"))
    }

    private func completed(_ events: [DeliverableRunEvent]) throws -> Deliverable {
        guard case .completed(let deliverable)? = events.last else {
            throw FakeError(message: "no document: \(events)")
        }
        return deliverable
    }

    // MARK: - Cut off at the length limit (R3-1 / R4-2)

    func testASingleCallStoppedAtTheLengthLimitIsKeptAndMarkedIncomplete() async throws {
        for reason in ["length", "max_tokens", "model_context_window_exceeded", "LENGTH "] {
            let harness = try await DeliverableHarness(privacy: .personal)
            let model = Destination.onDevice.makeModel()
            model.script([.stopped("A summary that stops mid", reason: reason)])
            let document = try completed(try await harness.run(model: model))
            XCTAssertTrue(document.isCutOff, reason)
            XCTAssertEqual(document.text, "A summary that stops mid", "the text is kept: never lose work")
            let stored = try await harness.deliverables.fetchDeliverable(id: document.id)
            XCTAssertEqual(stored?.isCutOff, true, "the mark is stored with the document")
            let runs = await harness.deliverables.runs
            XCTAssertEqual(runs.last?.status, .succeeded)
        }
    }

    /// `normalizedStopReason == nil` is unknown: neither a cut-off nor a claim of completeness, so nothing is marked.
    func testAFinishedOrUnknownStopIsNotMarked() async throws {
        for reason in ["stop", "end_turn", nil] as [String?] {
            let harness = try await DeliverableHarness(privacy: .personal)
            let model = Destination.onDevice.makeModel()
            model.script([.stopped("A whole summary.", reason: reason)])
            let document = try completed(try await harness.run(model: model))
            XCTAssertFalse(document.isCutOff, "\(reason ?? "nil")")
        }
    }

    /// A map step cut off loses its part's last facts, so the combined document is incomplete too.
    func testAMapStepStoppedAtTheLimitMarksTheCombinedDocument() async throws {
        let harness = try await longHarness()
        let model = Destination.onDevice.makeModel(contextTokens: 4_096)
        model.script([.stopped("notes for part one, cut", reason: "length")])
        let document = try completed(try await harness.run(model: model))
        XCTAssertGreaterThan(model.requests.count, 2, "the source must take several calls to prove this")
        XCTAssertTrue(document.isCutOff)
    }

    func testTheCombineStepStoppedAtTheLimitMarksTheDocument() async throws {
        let harness = try await longHarness()
        let probe = Destination.onDevice.makeModel(contextTokens: 4_096)
        _ = try await harness.run(model: probe)
        let calls = probe.requests.count
        let model = Destination.onDevice.makeModel(contextTokens: 4_096)
        model.script(
            Array(repeating: RecordingLanguageModel.Reply.text("notes"), count: calls - 1)
                + [.stopped("The combined document stops", reason: "length")])
        let document = try completed(try await harness.run(model: model))
        XCTAssertTrue(document.isCutOff)
        XCTAssertEqual(document.text, "The combined document stops")
    }

    func testAnAskAnswerStoppedAtTheLimitSaysSo() async throws {
        let harness = try await DeliverableHarness(privacy: .personal)
        let model = Destination.onDevice.makeModel()
        model.script([.stopped("It moves to Thurs", reason: "length")])
        var answer: AskAnswer?
        for try await event in harness.service.ask(
            question: "When?", transcriptionID: harness.transcript.id, model: model)
        {
            if case .answered(let value) = event { answer = value }
        }
        XCTAssertEqual(answer?.isCutOff, true)
        XCTAssertEqual(answer?.text, "It moves to Thurs")
    }

    func testTheRunViewModelSaysTheDocumentIsIncomplete() async throws {
        let harness = try await DeliverableHarness(privacy: .personal)
        let model = Destination.onDevice.makeModel()
        model.script([.stopped("Cut", reason: "length")])
        let run = DeliverableRunViewModel(
            service: harness.service, model: model, transcriptionID: harness.transcript.id,
            request: .template(id: BuiltInTemplates.summary.id, userNotes: nil))
        await run.start()
        XCTAssertEqual(
            run.cutOffNotice, "The model stopped at its length limit — this document is incomplete.")
        guard case .completed(let document) = run.phase else { return XCTFail("\(run.phase)") }
        let screen = DeliverableDocumentViewModel(id: document.id, store: harness.deliverables)
        await screen.load()
        XCTAssertEqual(screen.cutOffNotice, Deliverable.cutOffMessage, "the document screen says so after relaunch")

        let whole = Destination.onDevice.makeModel()
        let wholeRun = DeliverableRunViewModel(
            service: harness.service, model: whole, transcriptionID: harness.transcript.id,
            request: .template(id: BuiltInTemplates.summary.id, userNotes: nil))
        await wholeRun.start()
        XCTAssertNil(wholeRun.cutOffNotice)
    }

    func testAnEditStoppedAtTheLimitIsAMarkedVersionAndRestoreFollowsTheMark() async throws {
        let harness = try await DeliverableHarness(privacy: .personal)
        let document = try completed(try await harness.run(model: Destination.onDevice.makeModel()))
        let model = Destination.onDevice.makeModel()
        model.script([.stopped("A rewrite that stops", reason: "length")])
        var edited: Deliverable?
        for try await event in harness.service.edit(
            deliverableID: document.id, instruction: "Expand it", spoken: false, model: model)
        {
            if case .completed(let value) = event { edited = value }
        }
        XCTAssertEqual(edited?.isCutOff, true)
        let versions = try await harness.deliverables.fetchDeliverableVersions(deliverableID: document.id)
        XCTAssertEqual(versions.map(\.isCutOff), [false, true])

        // Restoring the whole original clears the mark; restoring the cut-off rewrite brings it back.
        let sheet = DocumentVersionsViewModel(
            deliverableID: document.id, documents: harness.deliverables, store: harness.deliverables)
        await sheet.load()
        let original = await sheet.restore(versions[0])
        XCTAssertEqual(original?.isCutOff, false)
        let cut = await sheet.restore(versions[1])
        XCTAssertEqual(cut?.isCutOff, true)
    }

    // MARK: - The ledger counts every call that went out (R4-4)

    func testAFailedMultiCallRunCountsEveryCallThatWentOut() async throws {
        let harness = try await longHarness()
        let model = Destination.onDevice.makeModel(contextTokens: 4_096)
        model.script([.text("notes one"), .failsAfter("notes two, then", .streamingError("synthetic drop"))])
        do {
            _ = try await harness.run(model: model)
            XCTFail("the run must fail")
        } catch {}
        let runs = await harness.deliverables.runs
        let run = try XCTUnwrap(runs.last)
        XCTAssertEqual(run.status, .failed)
        XCTAssertEqual(run.callCount, model.requests.count)
        XCTAssertEqual(run.callCount, 2)
        XCTAssertGreaterThan(run.inputCharacters, 0, "content went out")
        XCTAssertNotNil(run.promptTokens, "the first call's usage is kept")
    }

    func testARunRefusedMidRunCountsTheCallThatAlreadyWentOut() async throws {
        let harness = try await longHarness()
        let cloud = Destination.cloud.makeModel(contextTokens: 4_096)
        let transcripts = harness.transcripts
        let id = harness.transcript.id
        cloud.onEachCall { call in
            if call == 1 { await transcripts.setPrivacyClass(.clinical, for: id) }
        }
        do {
            _ = try await harness.run(model: cloud)
            XCTFail("the run must stop once the transcript became clinical")
        } catch DeliverableError.privacyOverrideRequired {}
        let runs = await harness.deliverables.runs
        let run = try XCTUnwrap(runs.last)
        XCTAssertEqual(run.status, .refused)
        XCTAssertEqual(run.callCount, cloud.requests.count)
        XCTAssertEqual(run.callCount, 1)
        XCTAssertGreaterThan(run.inputCharacters, 0)
        XCTAssertEqual(run.privacyClass, .personal, "the call that went out was personal when it was sent")
    }

    func testACancelledRunCountsTheCallInFlight() async throws {
        let harness = try await longHarness()
        let model = Destination.onDevice.makeModel(contextTokens: 4_096)
        let started = Signal()
        let release = Signal()
        model.onEachCall { call in
            guard call == 2 else { return }
            started.fire()
            await release.wait()
        }
        let service = harness.service
        let id = harness.transcript.id
        let task = Task {
            for try await _ in service.generate(
                templateID: BuiltInTemplates.summary.id, transcriptionID: id, model: model)
            {}
        }
        await started.wait()
        task.cancel()
        release.fire()
        _ = await task.result
        // The ledger row is written by the cancelled run itself; wait for it without sleeping.
        var runs = await harness.deliverables.runs
        for _ in 0..<10_000 where runs.isEmpty {
            await Task.yield()
            runs = await harness.deliverables.runs
        }
        let run = try XCTUnwrap(runs.last)
        XCTAssertEqual(run.status, .cancelled)
        XCTAssertEqual(run.callCount, 2, "the call in flight went out")
    }

    func testAModelThatCannotRunRecordsNoInput() async throws {
        let harness = try await DeliverableHarness(privacy: .personal)
        let model = Destination.onDevice.makeModel()
        model.setAvailability(.unavailable(.appleIntelligenceNotEnabled))
        do {
            _ = try await harness.run(model: model)
            XCTFail("an unavailable model must fail")
        } catch {}
        let runs = await harness.deliverables.runs
        let run = try XCTUnwrap(runs.last)
        XCTAssertEqual(run.callCount, 0)
        XCTAssertEqual(run.inputCharacters, 0, "nothing was sent")
    }

    // MARK: - A class raised mid-run (R4-11, R4-12)

    func testADocumentFinishedAfterItsTranscriptWasRaisedIsStoredClinical() async throws {
        let harness = try await longHarness()
        let onDevice = Destination.onDevice.makeModel(contextTokens: 4_096)
        let transcripts = harness.transcripts
        let id = harness.transcript.id
        onDevice.onEachCall { call in
            if call == 1 { await transcripts.setPrivacyClass(.clinical, for: id) }
        }
        let document = try completed(try await harness.run(model: onDevice))
        XCTAssertEqual(document.privacyClass, .clinical)
        let stored = try await harness.deliverables.fetchDeliverable(id: document.id)
        XCTAssertEqual(stored?.privacyClass, .clinical)
        let runs = await harness.deliverables.runs
        let run = try XCTUnwrap(runs.last)
        XCTAssertEqual(run.privacyClass, .clinical)
    }

    /// Raised after the last call, before the document is stored: still stored clinical.
    func testARaiseAfterTheLastCallStillMakesTheDocumentClinical() async throws {
        let harness = try await DeliverableHarness(privacy: .personal)
        let model = Destination.onDevice.makeModel()
        let transcripts = harness.transcripts
        let id = harness.transcript.id
        model.onEachCall { _ in await transcripts.setPrivacyClass(.clinical, for: id) }
        let document = try completed(try await harness.run(model: model))
        XCTAssertEqual(document.privacyClass, .clinical)
    }

    func testAnEditIsSentWithAClassRaisedAfterRouting() async throws {
        let harness = try await DeliverableHarness(privacy: .personal)
        let document = try completed(try await harness.run(model: Destination.onDevice.makeModel()))
        let model = ClassRaisingModel(
            base: Destination.onDevice.makeModel(), store: harness.transcripts, id: harness.transcript.id)
        var edited: Deliverable?
        for try await event in harness.service.edit(
            deliverableID: document.id, instruction: "Tighten it", spoken: false, model: model)
        {
            if case .completed(let value) = event { edited = value }
        }
        XCTAssertEqual(model.base.requests.last?.privacyClass, .clinical, "sampled at the clinical profile")
        XCTAssertEqual(edited?.privacyClass, .clinical)
        let versions = try await harness.deliverables.fetchDeliverableVersions(deliverableID: document.id)
        XCTAssertEqual(versions.last?.privacyClass, .clinical)
    }

    // MARK: - Edit by voice edits the draft on screen (R5-9, service side)

    func testAnEditRewritesTheDraftAndKeepsItAsAVersion() async throws {
        let harness = try await DeliverableHarness(privacy: .personal)
        let document = try completed(try await harness.run(model: Destination.onDevice.makeModel()))
        let screen = DeliverableDocumentViewModel(deliverable: document, store: harness.deliverables)
        screen.draft = "Generated document. Plus the person's unsaved line."
        let model = Destination.onDevice.makeModel()
        model.script([.text("A shorter version of the draft.")])
        let run = DeliverableRunViewModel(
            service: harness.service, model: model, transcriptionID: document.transcriptionID,
            request: .edit(
                deliverableID: document.id, instruction: "Shorter", spoken: true, baseText: screen.draft))
        await run.start()
        guard case .completed(let edited) = run.phase else { return XCTFail("\(run.phase)") }

        XCTAssertTrue(model.everythingReceived.contains("Plus the person's unsaved line."), "the draft was edited")
        let versions = try await harness.deliverables.fetchDeliverableVersions(deliverableID: document.id)
        // Fix round 1: the model's text stays version 1 with its provenance; the draft is the person's hand edit.
        XCTAssertEqual(
            versions.map(\.text),
            [
                "Generated document.", "Generated document. Plus the person's unsaved line.",
                "A shorter version of the draft.",
            ])
        XCTAssertEqual(versions.map(\.origin), [.original, .handEdit, .spokenEdit])
        XCTAssertEqual(versions[0].engineID, document.engineID, "the original keeps the model's provenance")
        XCTAssertEqual(versions[0].provider, document.provider)
        XCTAssertNil(versions[1].engineID, "the draft is the person's, not the model's")
        XCTAssertNil(versions[1].instruction)
        screen.applyEdit(edited)
        XCTAssertEqual(screen.draft, "A shorter version of the draft.", "the result is shown, not hidden by the draft")
        XCTAssertFalse(screen.hasUnsavedChanges)
    }

    /// A document that already has versions: the draft is appended as a hand edit after them, nothing earlier changes.
    func testAnEditOfADraftAfterEarlierVersionsAppendsTheDraftThenTheRewrite() async throws {
        let harness = try await DeliverableHarness(privacy: .personal)
        let document = try completed(try await harness.run(model: Destination.onDevice.makeModel()))
        let first = Destination.onDevice.makeModel()
        first.script([.text("Version two.")])
        for try await _ in harness.service.edit(
            deliverableID: document.id, instruction: "Shorter", spoken: false, model: first)
        {}
        let before = try await harness.deliverables.fetchDeliverableVersions(deliverableID: document.id)
        XCTAssertEqual(before.map(\.text), ["Generated document.", "Version two."])

        let second = Destination.onDevice.makeModel()
        second.script([.text("Version four.")])
        for try await _ in harness.service.edit(
            deliverableID: document.id, instruction: "Tighten", spoken: true, model: second,
            baseText: "Version two, with the person's line.")
        {}
        let after = try await harness.deliverables.fetchDeliverableVersions(deliverableID: document.id)
        XCTAssertEqual(
            after.map(\.text),
            ["Generated document.", "Version two.", "Version two, with the person's line.", "Version four."])
        XCTAssertEqual(after.map(\.origin), [.original, .typedEdit, .handEdit, .spokenEdit])
        XCTAssertEqual(Array(after.prefix(2)), before, "earlier versions never change")
        let stored = try await harness.deliverables.fetchDeliverable(id: document.id)
        XCTAssertEqual(stored?.text, "Version four.")
    }

    func testAFailedEditOfADraftSavesNothing() async throws {
        let harness = try await DeliverableHarness(privacy: .personal)
        let document = try completed(try await harness.run(model: Destination.onDevice.makeModel()))
        let model = Destination.onDevice.makeModel()
        model.script([.error(.streamingError("synthetic failure"))])
        do {
            for try await _ in harness.service.edit(
                deliverableID: document.id, instruction: "Shorter", spoken: true, model: model,
                baseText: "An unsaved draft.")
            {}
            XCTFail("the edit must fail")
        } catch {}
        let stored = try await harness.deliverables.fetchDeliverable(id: document.id)
        XCTAssertEqual(stored?.text, "Generated document.", "the screen keeps the draft; the store is untouched")
    }
}

/// A language model that marks the transcript clinical when the service asks for its context window, which an edit
/// does after routing and before its call: the class rises between routing and the call (review R4-12).
private final class ClassRaisingModel: LanguageModel {
    let base: RecordingLanguageModel
    private let store: FakeStore
    private let id: UUID

    init(base: RecordingLanguageModel, store: FakeStore, id: UUID) {
        self.base = base
        self.store = store
        self.id = id
    }

    var descriptor: EngineDescriptor { base.descriptor }
    var endpointHost: String? { base.endpointHost }

    func contextWindowTokens() async -> Int? {
        await store.setPrivacyClass(.clinical, for: id)
        return await base.contextWindowTokens()
    }

    func availability() async -> LanguageModelAvailability { await base.availability() }

    func generate(_ request: GenerationRequest) -> AsyncThrowingStream<GenerationEvent, Error> {
        base.generate(request)
    }
}
