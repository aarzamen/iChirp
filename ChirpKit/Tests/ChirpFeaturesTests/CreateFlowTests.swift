import ChirpCore
import Foundation
import XCTest

@testable import ChirpFeatures

/// Plan 022 Step 2: every input the Create sheet offers reaches every output, each stage fails and retries on its own,
/// and clinical content never leaves without the per-run question. Everything is synthetic.
@MainActor
final class CreateFlowTests: XCTestCase {
    static let marker = "SYNTHETIC-KESTREL-4417"

    static let inputs: [CreateInput] = [
        .speak,
        .text("Synthetic note \(marker)\nThe synthetic budget review moves to Friday."),
        .link("https://example.com/synthetic-episode.mp3"),
        .file(URL(fileURLWithPath: "/tmp/synthetic-memo.m4a")),
    ]

    static let outputs: [CreateOutput] = [
        .transcript,
        .summary,
        .document(templateID: BuiltInTemplates.meetingNotes.id),
        .voiceMessage(summarizeFirst: false),
        .voiceMessage(summarizeFirst: true),
    ]

    // MARK: - Every input × every output

    func testEveryInputReachesEveryOutput() async throws {
        for input in Self.inputs {
            for output in Self.outputs {
                let harness = try await CreateHarness()
                let flow = harness.makeFlow()
                let model = RecordingLanguageModel(locality: .onDevice)
                await flow.start(CreateRequest(input: input, output: output), makeModel: { model })
                let label = "\(input.kind) → \(output)"
                XCTAssertEqual(flow.phase, .finished, label)

                let item = try XCTUnwrap(flow.item, label)
                XCTAssertEqual(item.sourceType, CreateHarness.sourceType(for: input), label)
                XCTAssertEqual(flow.stages[.input], .done, label)
                XCTAssertEqual(flow.stages[.transcribe], input.kind == .text ? .skipped : .done, label)
                XCTAssertEqual(flow.stages[.operation], output.templateID == nil ? .skipped : .done, label)
                XCTAssertEqual(flow.stages[.output], .done, label)
                let items = try await harness.transcripts.fetchAll()
                XCTAssertEqual(items.count, 1, "one item per chain: \(label)")

                let stored = try await harness.deliverables.fetchDeliverables(transcriptionID: item.id)
                if let templateID = output.templateID {
                    XCTAssertEqual(stored.count, 1, label)
                    XCTAssertEqual(stored.first?.promptID, templateID, label)
                    XCTAssertEqual(flow.deliverable?.id, stored.first?.id, label)
                    XCTAssertEqual(model.requests.count, 1, label)
                } else {
                    XCTAssertTrue(stored.isEmpty, label)
                    XCTAssertTrue(model.requests.isEmpty, "no model for \(label)")
                }

                if case .voiceMessage(let summarizeFirst) = output {
                    let voice = try XCTUnwrap(harness.voices.last, label)
                    XCTAssertEqual(voice.requests.count, 1, label)
                    let request = try XCTUnwrap(voice.requests.first)
                    XCTAssertEqual(request.itemID, item.id, label)
                    if summarizeFirst {
                        XCTAssertEqual(request.source, .deliverable(id: try XCTUnwrap(flow.deliverable?.id)), label)
                        XCTAssertEqual(request.text, "Generated document.", label)
                    } else {
                        let expected: VoiceSource =
                            input.kind == .text ? .document(id: item.id) : .transcript(id: item.id)
                        XCTAssertEqual(request.source, expected, label)
                        XCTAssertFalse(request.text.isEmpty, label)
                    }
                    XCTAssertNotNil(flow.voiceMessageFile, label)
                } else {
                    XCTAssertTrue(harness.voices.isEmpty, "no voice for \(label)")
                }
            }
        }
    }

    func testTheTranscriptIsNeverOverwritten() async throws {
        let harness = try await CreateHarness()
        let flow = harness.makeFlow()
        let text = "Synthetic original \(Self.marker)"
        await flow.start(
            CreateRequest(input: .text(text), output: .summary),
            makeModel: { RecordingLanguageModel(locality: .onDevice) })
        XCTAssertEqual(flow.phase, .finished)
        let stored = try await harness.transcripts.fetch(id: try XCTUnwrap(flow.itemID))
        XCTAssertEqual(stored?.rawTranscript, text)
        XCTAssertEqual(flow.deliverable?.text, "Generated document.")
    }

    // MARK: - Failure and Retry at each stage

    func testInputFailureStopsAndRetryMakesTheItemOnce() async throws {
        let harness = try await CreateHarness()
        harness.linkError = FakeError(message: "That link isn’t a podcast or media file.")
        let flow = harness.makeFlow()
        await flow.start(
            CreateRequest(input: .link("https://example.com/page"), output: .transcript),
            makeModel: { RecordingLanguageModel(locality: .onDevice) })
        XCTAssertEqual(flow.phase, .failed(.input, "That link isn’t a podcast or media file."))
        XCTAssertNil(flow.itemID)
        XCTAssertEqual(flow.stages[.transcribe], .pending)

        harness.linkError = nil
        await flow.retry()
        XCTAssertEqual(flow.phase, .finished)
        let items = try await harness.transcripts.fetchAll()
        XCTAssertEqual(items.count, 1)
    }

    func testTranscriptionFailureRetriesTheSameItem() async throws {
        let harness = try await CreateHarness()
        harness.failNextJobs = 1
        let flow = harness.makeFlow()
        await flow.start(
            CreateRequest(input: .file(URL(fileURLWithPath: "/tmp/synthetic.m4a")), output: .summary),
            makeModel: { RecordingLanguageModel(locality: .onDevice) })
        XCTAssertEqual(flow.phase, .failed(.transcribe, CreateHarness.jobFailure))
        XCTAssertEqual(flow.stages[.input], .done)
        XCTAssertEqual(flow.stages[.operation], .pending)
        let id = try XCTUnwrap(flow.itemID)

        await flow.retry()
        XCTAssertEqual(harness.retried, [id])
        XCTAssertEqual(flow.phase, .finished)
        XCTAssertEqual(flow.itemID, id)
        let items = try await harness.transcripts.fetchAll()
        XCTAssertEqual(items.count, 1, "Retry reuses the item")
    }

    func testOperationFailureRetriesOnlyTheOperation() async throws {
        let harness = try await CreateHarness()
        let flow = harness.makeFlow()
        let model = RecordingLanguageModel(locality: .onDevice)
        model.setAvailability(.unavailable(.modelNotReady))
        await flow.start(
            CreateRequest(input: .text("Synthetic text"), output: .summary), makeModel: { model })
        guard case .failed(.operation, _) = flow.phase else {
            return XCTFail("expected an operation failure, got \(flow.phase)")
        }
        let itemID = flow.itemID

        model.setAvailability(.available)
        await flow.retry()
        XCTAssertEqual(flow.phase, .finished)
        XCTAssertEqual(flow.itemID, itemID)
        let stored = try await harness.deliverables.fetchDeliverables(transcriptionID: try XCTUnwrap(itemID))
        XCTAssertEqual(stored.count, 1)
    }

    func testAModelThatCannotBeBuiltSendsNothing() async throws {
        let harness = try await CreateHarness()
        let flow = harness.makeFlow()
        await flow.start(
            CreateRequest(input: .text("Synthetic text"), output: .summary),
            makeModel: { throw FakeError(message: "The key for this provider is missing.") })
        XCTAssertEqual(flow.phase, .failed(.operation, "The key for this provider is missing."))
        let runs = try await harness.deliverables.fetchRuns(limit: 10)
        XCTAssertTrue(runs.isEmpty)
    }

    func testOutputFailureRetriesTheVoiceMessage() async throws {
        let harness = try await CreateHarness()
        harness.voiceScript = .fail("Could not reach the voice provider.")
        let flow = harness.makeFlow()
        await flow.start(
            CreateRequest(input: .text("Synthetic text"), output: .voiceMessage(summarizeFirst: false)),
            makeModel: { RecordingLanguageModel(locality: .onDevice) })
        XCTAssertEqual(flow.phase, .failed(.output, "Could not reach the voice provider."))

        await flow.retry()
        XCTAssertEqual(harness.voices.count, 1, "the same voice message retries")
        XCTAssertEqual(harness.voices.first?.retries, 1)
        XCTAssertEqual(flow.phase, .finished)
        XCTAssertNotNil(flow.voiceMessageFile)
    }

    func testSpeechDiscardedEndsTheChainWithoutAnItem() async throws {
        let harness = try await CreateHarness()
        harness.speechOutcome = .discarded
        let flow = harness.makeFlow()
        await flow.start(
            CreateRequest(input: .speak, output: .summary),
            makeModel: { RecordingLanguageModel(locality: .onDevice) })
        XCTAssertEqual(flow.phase, .cancelled)
        XCTAssertNil(flow.itemID)
    }

    func testSpeechWhoseFinalPassFailedRetriesTheDictation() async throws {
        let harness = try await CreateHarness()
        let kept = try await harness.insertRow(sourceType: .dictation, status: .failed)
        harness.speechOutcome = .failed(kept, "Didn’t catch that.")
        let flow = harness.makeFlow()
        await flow.start(
            CreateRequest(input: .speak, output: .transcript),
            makeModel: { RecordingLanguageModel(locality: .onDevice) })
        XCTAssertEqual(flow.phase, .failed(.transcribe, "Didn’t catch that."))
        XCTAssertEqual(flow.itemID, kept)

        await flow.retry()
        XCTAssertEqual(harness.retried, [kept])
        XCTAssertEqual(flow.phase, .finished)
    }

    func testSpeechWithoutARecordingFailsAtInput() async throws {
        let harness = try await CreateHarness()
        harness.speechOutcome = .failed(nil, "Parakeet needs the microphone to dictate.")
        let flow = harness.makeFlow()
        await flow.start(
            CreateRequest(input: .speak, output: .transcript),
            makeModel: { RecordingLanguageModel(locality: .onDevice) })
        XCTAssertEqual(flow.phase, .failed(.input, "Parakeet needs the microphone to dictate."))
    }

    func testCancelDuringTheOperationStoresNothing() async throws {
        let harness = try await CreateHarness()
        let flow = harness.makeFlow()
        let model = RecordingLanguageModel(locality: .onDevice)
        let hold = Hold()
        model.onEachCall { _ in
            hold.entered.fire()
            await hold.release.wait()
        }
        let running = Task { @MainActor in
            await flow.start(CreateRequest(input: .text("Synthetic text"), output: .summary), makeModel: { model })
        }
        await hold.entered.wait()
        flow.cancel()
        XCTAssertEqual(flow.phase, .cancelled)
        hold.release.fire()
        await running.value
        XCTAssertEqual(flow.phase, .cancelled)
        let stored = try await harness.deliverables.fetchDeliverables(transcriptionID: try XCTUnwrap(flow.itemID))
        XCTAssertTrue(stored.isEmpty, "a cancelled run stores nothing")
    }

    /// Review M1: a Stop while the operation's route is checked (before its task exists) stops it: nothing is sent,
    /// no document is stored, and no question comes up over the stopped chain.
    func testCancelWhileTheOperationIsRoutedStoresNothing() async throws {
        for privacy in [PrivacyClass.personal, .clinical] {
            let harness = try await CreateHarness()
            let flow = harness.makeFlow()
            let cloud = RecordingLanguageModel(locality: .cloud, host: "api.example.com")
            // A text item makes no fetch before the route check, so the next fetch is the route's.
            let hold = await harness.transcripts.holdNext([.fetch])
            let running = Task { @MainActor in
                await flow.start(
                    CreateRequest(input: .text("Synthetic text"), output: .summary, privacyClass: privacy),
                    makeModel: { cloud })
            }
            await hold.entered.wait()
            XCTAssertEqual(flow.operationRun?.phase, .checking, "\(privacy)")
            flow.cancel()
            hold.release.fire()
            await running.value
            await settle()
            XCTAssertEqual(flow.phase, .cancelled, "\(privacy)")
            XCTAssertTrue(cloud.requests.isEmpty, "\(privacy)")
            if case .needsConfirmation = flow.operationRun?.phase { XCTFail("a question over a stopped chain") }
            let stored = try await harness.deliverables.fetchDeliverables(transcriptionID: try XCTUnwrap(flow.itemID))
            XCTAssertTrue(stored.isEmpty, "\(privacy)")
        }
    }

    /// Review M2: a chain that is dropped or reset cancels its voice message, so a failed one's chunk audio (possibly
    /// clinical text) does not wait in `tmp` for the next launch.
    func testResetCancelsAFailedVoiceMessage() async throws {
        let harness = try await CreateHarness()
        harness.voiceScript = .fail("Could not reach the voice provider.")
        let flow = harness.makeFlow()
        await flow.start(
            CreateRequest(input: .text("Synthetic text"), output: .voiceMessage(summarizeFirst: false)),
            makeModel: { RecordingLanguageModel(locality: .onDevice) })
        XCTAssertEqual(flow.phase, .failed(.output, "Could not reach the voice provider."))
        let voice = try XCTUnwrap(harness.voices.first)
        XCTAssertEqual(voice.cancels, 0)
        flow.reset()
        XCTAssertEqual(voice.cancels, 1, "the failed voice message's work is removed")
        XCTAssertEqual(flow.phase, .idle)
    }

    // MARK: - Review I1: a Stop never leaves an item less private than the person chose

    /// Link and File, stopped while each stage runs (the lookup or copy, the job, the model call, the voice message),
    /// with Clinical on: the item the chain made exists once, the stopped chain knows it, and it was never Personal,
    /// not even for a moment.
    func testStopAtEveryStageNeverLeavesALessPrivateItem() async throws {
        let inputs: [CreateInput] = [
            .link("https://example.com/synthetic-episode.mp3"),
            .file(URL(fileURLWithPath: "/tmp/synthetic-memo.m4a")),
        ]
        for input in inputs {
            for stage in CreateFlow.Stage.allCases {
                let label = "\(input.kind) stopped during \(stage)"
                let harness = try await CreateHarness()
                let hold = Hold()
                harness.hold = (stage, hold)
                let model = RecordingLanguageModel(locality: .onDevice)
                if stage == .operation {
                    model.onEachCall { _ in
                        hold.entered.fire()
                        await hold.release.wait()
                    }
                }
                let flow = harness.makeFlow()
                let running = Task { @MainActor in
                    await flow.start(
                        CreateRequest(
                            input: input, output: .voiceMessage(summarizeFirst: true), privacyClass: .clinical),
                        makeModel: { model })
                }
                await hold.entered.wait()
                flow.cancel()
                XCTAssertEqual(flow.phase, .cancelled, label)
                hold.release.fire()
                await running.value
                await settle()

                XCTAssertEqual(flow.phase, .cancelled, label)
                let rows = try await harness.transcripts.fetchAll()
                XCTAssertEqual(rows.count, 1, "what was already made stays, once: \(label)")
                let row = try XCTUnwrap(rows.first, label)
                XCTAssertEqual(flow.itemID, row.id, "the stopped chain knows the item it made: \(label)")
                XCTAssertEqual(row.privacyClass, .clinical, label)
                let history = await harness.transcripts.classHistory(row.id)
                XCTAssertFalse(history.isEmpty, label)
                XCTAssertEqual(Set(history), [.clinical], "never Personal, not even for a moment: \(label)")
            }
        }
    }

    /// A service that made the row with the default class (a dictation's row is made by the Dictating screen): a Stop
    /// during the input still leaves it at the chosen class, because the raise comes before the Stop is looked at.
    func testAStoppedInputStillRaisesARowMadeWithTheDefaultClass() async throws {
        let harness = try await CreateHarness()
        harness.ignoresRequestedClass = true
        let hold = Hold()
        harness.hold = (.input, hold)
        let flow = harness.makeFlow()
        let running = Task { @MainActor in
            await flow.start(
                CreateRequest(
                    input: .link("https://example.com/synthetic.mp3"), output: .summary, privacyClass: .clinical),
                makeModel: { RecordingLanguageModel(locality: .onDevice) })
        }
        await hold.entered.wait()
        flow.cancel()
        hold.release.fire()
        await running.value
        await settle()
        let id = try XCTUnwrap(flow.itemID)
        let row = try await harness.transcripts.fetch(id: id)
        XCTAssertEqual(row?.privacyClass, .clinical)
        XCTAssertEqual(flow.phase, .cancelled)
    }

    /// A chain dropped (Create another, Done) while its dictation was still being saved: the dictation's row, made
    /// with the default class by the Dictating screen, is still raised to the class the chain was started with.
    func testAResetDuringTheInputStillRaisesTheItemItMade() async throws {
        let harness = try await CreateHarness()
        let hold = Hold()
        harness.hold = (.input, hold)
        let flow = harness.makeFlow()
        let running = Task { @MainActor in
            await flow.start(
                CreateRequest(input: .speak, output: .summary, privacyClass: .clinical),
                makeModel: { RecordingLanguageModel(locality: .onDevice) })
        }
        await hold.entered.wait()
        flow.reset()
        hold.release.fire()
        await running.value
        await settle()
        let rows = try await harness.transcripts.fetchAll()
        XCTAssertEqual(rows.map(\.privacyClass), [.clinical])
        XCTAssertNil(flow.itemID, "a reset chain reports nothing")
        XCTAssertEqual(flow.phase, .idle)
    }

    // MARK: - Privacy

    func testClinicalChainWaitsForTheQuestionAndOnlySendAnswers() async throws {
        let harness = try await CreateHarness()
        let flow = harness.makeFlow()
        let cloud = RecordingLanguageModel(locality: .cloud, host: "api.example.com")
        await flow.start(
            CreateRequest(input: .speak, output: .summary, privacyClass: .clinical), makeModel: { cloud })
        XCTAssertEqual(flow.phase, .waitingForAnswer(.operation))
        XCTAssertTrue(cloud.requests.isEmpty, "nothing is sent before the answer")
        let item = try await harness.transcripts.fetch(id: try XCTUnwrap(flow.itemID))
        XCTAssertEqual(item?.privacyClass, .clinical, "the dictation row was raised before any other step")

        // Cancel in the dialog: nothing sent, the chain says so.
        let first = try XCTUnwrap(flow.operationRun)
        first.declineOverride()
        await settle()
        XCTAssertEqual(flow.phase, .failed(.operation, "Not sent. Nothing left this iPhone."))
        XCTAssertTrue(cloud.requests.isEmpty)

        // Retry asks again; Send in the dialog delivers exactly this run, then the chain finishes.
        await flow.retry()
        XCTAssertEqual(flow.phase, .waitingForAnswer(.operation))
        let second = try XCTUnwrap(flow.operationRun)
        XCTAssertFalse(first === second, "a fresh run and a fresh question")
        await second.confirmOverride()
        await settle()
        XCTAssertEqual(flow.phase, .finished)
        XCTAssertEqual(cloud.requests.count, 1)
        XCTAssertTrue(cloud.everythingReceived.contains(CreateHarness.dictationText))
        XCTAssertEqual(flow.deliverable?.privacyClass, .clinical)
    }

    func testAPersonalChainToTheCloudNeedsNoQuestion() async throws {
        let harness = try await CreateHarness()
        let flow = harness.makeFlow()
        let cloud = RecordingLanguageModel(locality: .cloud, host: "api.example.com")
        await flow.start(CreateRequest(input: .speak, output: .summary), makeModel: { cloud })
        XCTAssertEqual(flow.phase, .finished)
        XCTAssertEqual(cloud.requests.count, 1)
    }

    func testAClinicalDocumentMakesItsVoiceMessageClinical() async throws {
        let harness = try await CreateHarness()
        let flow = harness.makeFlow()
        await flow.start(
            CreateRequest(
                input: .text("Synthetic encounter note"), output: .voiceMessage(summarizeFirst: false),
                privacyClass: .clinical),
            makeModel: { RecordingLanguageModel(locality: .onDevice) })
        XCTAssertEqual(flow.phase, .finished)
        let request = try XCTUnwrap(harness.voices.first?.requests.first)
        XCTAssertEqual(request.privacyClass, .clinical)
        XCTAssertEqual(request.source, .document(id: try XCTUnwrap(flow.itemID)))
    }

    func testASOAPNoteFromAPersonalItemIsClinical() async throws {
        let harness = try await CreateHarness()
        let flow = harness.makeFlow()
        let soap = BuiltInTemplates.soapNote.id
        await flow.start(
            CreateRequest(input: .text("Synthetic visit"), output: .document(templateID: soap)),
            makeModel: { RecordingLanguageModel(locality: .onDevice) })
        XCTAssertEqual(flow.phase, .finished)
        XCTAssertEqual(flow.deliverable?.privacyClass, .clinical, "the template's output class raises the document")
        let item = try await harness.transcripts.fetch(id: try XCTUnwrap(flow.itemID))
        XCTAssertEqual(item?.privacyClass, .personal, "the item keeps its own class; its effective class is clinical")
        let effective = try await EffectivePrivacyClass.of(try XCTUnwrap(item), in: harness.deliverables)
        XCTAssertEqual(effective, .clinical)
    }

    func testTheVoiceQuestionWaitsForTheDialog() async throws {
        let harness = try await CreateHarness()
        harness.voiceScript = .ask
        let flow = harness.makeFlow()
        await flow.start(
            CreateRequest(
                input: .text("Synthetic note"), output: .voiceMessage(summarizeFirst: false), privacyClass: .clinical),
            makeModel: { RecordingLanguageModel(locality: .onDevice) })
        XCTAssertEqual(flow.phase, .waitingForAnswer(.output))
        let voice = try XCTUnwrap(harness.voices.first)
        XCTAssertNil(flow.voiceMessageFile)

        voice.answer(proceed: false)
        await settle()
        XCTAssertEqual(flow.phase, .failed(.output, "No voice message was made. Nothing left this iPhone."))
    }

    func testTheVoiceQuestionAnsweredYesFinishes() async throws {
        let harness = try await CreateHarness()
        harness.voiceScript = .ask
        let flow = harness.makeFlow()
        await flow.start(
            CreateRequest(input: .text("Synthetic note"), output: .voiceMessage(summarizeFirst: false)),
            makeModel: { RecordingLanguageModel(locality: .onDevice) })
        try XCTUnwrap(harness.voices.first).answer(proceed: true)
        await settle()
        XCTAssertEqual(flow.phase, .finished)
        XCTAssertNotNil(flow.voiceMessageFile)
    }

    // MARK: - Remembered choices

    func testChoicesRoundTripAndDropARemovedTemplate() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "CreateFlowTests-\(UUID().uuidString)"))
        let store = UserDefaultsCreateChoicesStore(defaults: defaults)
        XCTAssertEqual(store.load(), CreateChoices())
        let template = UUID()
        let choices = CreateChoices(
            input: .link, output: .document, templateID: template, voiceSummarizeFirst: true, isClinical: true)
        store.save(choices)
        XCTAssertEqual(store.load(), choices)
        XCTAssertEqual(store.load().createOutput, .document(templateID: template))
        XCTAssertEqual(store.load().privacyClass, .clinical)
        XCTAssertNil(choices.validated(templateIDs: []).templateID)
        XCTAssertNil(choices.validated(templateIDs: []).createOutput, "a Document needs a template again")
        defaults.set(Data("not json".utf8), forKey: UserDefaultsCreateChoicesStore.key)
        XCTAssertEqual(store.load(), CreateChoices(), "unreadable falls back to the defaults")
    }

    /// Lets the tasks started by `onAnswered` run.
    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(20))
    }
}

// MARK: - Harness

/// The services a chain calls, as fakes over the in-memory stores and a real `DeliverableService`.
@MainActor
final class CreateHarness {
    static let dictationText = "Synthetic dictation \(CreateFlowTests.marker) about the synthetic schedule."
    static let jobFailure = "Synthetic decoder error."

    let transcripts = FakeStore()
    let deliverables = FakeDeliverableStore()
    let service: DeliverableService
    var speechOutcome: CreateSpeechOutcome?
    var linkError: Error?
    var failNextJobs = 0
    private(set) var retried: [UUID] = []
    var voiceScript: FakeVoiceMessage.Script = .finish
    private(set) var voices: [FakeVoiceMessage] = []
    /// Parks the chain inside `stage`'s service call (the lookup or copy, the job, the voice message; the model call is
    /// held by the test's model) until `release`.
    var hold: (stage: CreateFlow.Stage, hold: Hold)?
    /// Link and file rows are made with the default class, whatever the chain asked for.
    var ignoresRequestedClass = false

    init() async throws {
        let transcripts = self.transcripts
        service = DeliverableService(
            transcripts: transcripts, deliverables: deliverables, routingPolicy: { PrivacyRoutingPolicy() })
        try await service.installBuiltInTemplates()
    }

    static func sourceType(for input: CreateInput) -> Transcription.SourceType {
        switch input {
        case .speak: .dictation
        case .text: .text
        case .link: .url
        case .file: .file
        }
    }

    func makeFlow() -> CreateFlow {
        CreateFlow(
            dependencies: CreateFlowDependencies(
                recordSpeech: { [unowned self] in
                    await parkIfHeld(.input)
                    if let outcome = speechOutcome { return outcome }
                    var row = Transcription(sourceType: .dictation, fileName: "Dictation.wav", status: .completed)
                    row.rawTranscript = Self.dictationText
                    try? await transcripts.insert(row)
                    return .saved(row.id)
                },
                saveText: { [unowned self] text, privacyClass in
                    try await TextItemService(store: transcripts).save(text, privacyClass: privacyClass)
                },
                startLink: { [unowned self] _, privacyClass in
                    await parkIfHeld(.input)
                    if let linkError { throw linkError }
                    return try await insertRow(
                        sourceType: .url, status: .processing,
                        privacyClass: ignoresRequestedClass ? .personal : privacyClass)
                },
                startFile: { [unowned self] _, privacyClass in
                    await parkIfHeld(.input)
                    return try await insertRow(
                        sourceType: .file, status: .processing,
                        privacyClass: ignoresRequestedClass ? .personal : privacyClass)
                },
                waitForItem: { [unowned self] id in
                    await parkIfHeld(.transcribe)
                    return await finishJob(id)
                },
                retryItem: { [unowned self] id in
                    retried.append(id)
                    _ = try? await transcripts.transitionStatus(
                        id: id, from: [.failed, .cancelled, .interrupted], to: .processing, errorMessage: nil)
                },
                deliverables: service,
                makeVoiceMessage: { [unowned self] in
                    let voice = FakeVoiceMessage(script: voiceScript, hold: hold?.stage == .output ? hold?.hold : nil)
                    voices.append(voice)
                    return voice
                }))
    }

    /// Parks here once when `hold` names `stage`.
    private func parkIfHeld(_ stage: CreateFlow.Stage) async {
        guard let held = hold, held.stage == stage else { return }
        hold = nil
        held.hold.entered.fire()
        await held.hold.release.wait()
    }

    @discardableResult
    func insertRow(
        sourceType: Transcription.SourceType, status: Transcription.Status, privacyClass: PrivacyClass = .personal
    ) async throws -> UUID {
        let row = Transcription(
            sourceType: sourceType, fileName: "synthetic", status: status, privacyClass: privacyClass)
        try await transcripts.insert(row)
        return row.id
    }

    /// The job ends: a processing row completes with synthetic text, or fails while `failNextJobs` lasts.
    private func finishJob(_ id: UUID) async -> Transcription? {
        guard var row = try? await transcripts.fetch(id: id) else { return nil }
        guard row.status == .processing else { return row }
        if failNextJobs > 0 {
            failNextJobs -= 1
            row.status = .failed
            row.errorMessage = Self.jobFailure
        } else {
            row.status = .completed
            row.rawTranscript = "Synthetic transcript \(CreateFlowTests.marker) of a \(row.sourceType.rawValue) item."
            row.errorMessage = nil
        }
        try? await transcripts.update(row)
        return try? await transcripts.fetch(id: id)
    }
}

/// A `VoiceMessageProducing` that finishes, fails or asks, as scripted, and records what it was asked to speak.
@MainActor
final class FakeVoiceMessage: VoiceMessageProducing {
    enum Script {
        case finish
        case fail(String)
        case ask
    }

    private(set) var phase: VoiceMessagePhase = .idle
    var onAnswered: (@MainActor () -> Void)?
    private(set) var requests: [VoiceMessageRequest] = []
    private(set) var retries = 0
    private(set) var cancels = 0
    private let script: Script
    private let hold: Hold?

    init(script: Script, hold: Hold? = nil) {
        self.script = script
        self.hold = hold
    }

    func start(_ request: VoiceMessageRequest) async {
        requests.append(request)
        if let hold {
            hold.entered.fire()
            await hold.release.wait()
            guard cancels == 0 else { return }
        }
        switch script {
        case .finish: phase = .finished(Self.file(for: request))
        case .fail(let message): phase = .failed(message)
        case .ask:
            phase = .needsConfirmation(
                VoiceConfirmationRequest(
                    id: UUID(), engineID: "fake.voice", providerName: "Fake voice", locality: .cloud, host: nil))
        }
    }

    func retry() async {
        retries += 1
        guard let request = requests.last else { return }
        phase = .finished(Self.file(for: request))
    }

    func cancel() {
        cancels += 1
        phase = .idle
    }

    /// Stands in for the dialog's buttons.
    func answer(proceed: Bool) {
        guard case .needsConfirmation = phase, let request = requests.last else { return }
        phase = proceed ? .finished(Self.file(for: request)) : .idle
        onAnswered?()
    }

    private static func file(for request: VoiceMessageRequest) -> VoiceMessageFile {
        VoiceMessageFile(
            url: URL(fileURLWithPath: "/tmp/media/\(request.itemID.uuidString)/voice-1.m4a"),
            relativePath: "media/\(request.itemID.uuidString)/voice-1.m4a", durationMs: 1_000, chunkCount: 1)
    }
}
