import ChirpCore
import ChirpText
import Foundation
import XCTest

@testable import ChirpFeatures

/// Step 6 (plan 015): SOAP fields and medications from an invented encounter, on fakes. No model, no network.
@MainActor
final class StructuredExtractionServiceTests: XCTestCase {
    /// An invented clinic dictation. No real person.
    nonisolated static let encounter =
        "Synthetic patient Test Person Alpha. BP 142/88, pulse 76. Started lisinopril 10 mg by mouth once daily. "
        + "She is allergic to penicillin which causes hives. Plan is to recheck in three months."

    /// Words with invented timings: 400 ms each, 100 ms apart.
    nonisolated static func words(_ text: String) -> [WordTimestamp] {
        text.split(separator: " ").enumerated().map { index, word in
            WordTimestamp(word: String(word), startMs: index * 500, endMs: index * 500 + 400, confidence: 0.99)
        }
    }

    @MainActor private struct Harness {
        let store = FakeStore()
        let results = FakeStructuredResultStore()
        let settings: InMemoryStructureSettingsStore
        let service: StructuredExtractionService
        let id = UUID()

        init(
            privacy: PrivacyClass = .clinical, choice: StructureEngineChoice = .stub,
            needle: (any StructureModel)? = nil,
            needleAvailability: StructureEngineAvailability = .unavailable("Download Needle 3 first.")
        ) {
            var value = StructureSettings()
            value.engine = choice
            settings = InMemoryStructureSettingsStore(value)
            service = StructuredExtractionService(
                transcripts: store, results: results, settings: settings,
                engines: StructureEngines(needle: needle, needleAvailability: { needleAvailability }))
            self.privacy = privacy
        }

        let privacy: PrivacyClass

        func insertEncounter(_ text: String = StructuredExtractionServiceTests.encounter) async throws {
            var row = Transcription(id: id, sourceType: .dictation, fileName: "Synthetic.wav", status: .completed)
            row.rawTranscript = text
            row.wordTimestamps = StructuredExtractionServiceTests.words(text)
            try await store.insert(row)
            await store.setPrivacyClass(privacy, for: id)
        }
    }

    func testStubExtractsTheEncounterWithSpansVerdictsAndAStubLabel() async throws {
        let h = Harness()
        try await h.insertEncounter()
        let draft = try await h.service.extractSOAP(transcriptionID: h.id)
        XCTAssertTrue(draft.isStub)
        XCTAssertEqual(draft.run.catalogVersion, "soap-meds.v1")
        XCTAssertEqual(draft.run.engineID, "stub.rules")
        XCTAssertNil(draft.run.modelSHA256)

        let sections = DraftSections(draft: draft)
        XCTAssertEqual(sections.vitals.map(\.title), ["BP", "HR"])
        XCTAssertEqual(sections.vitals.map(\.detail), ["142/88 mmHg", "76/min"])
        XCTAssertEqual(sections.medications.map(\.title), ["lisinopril"])
        XCTAssertEqual(sections.medications.first?.detail, "10 mg · PO · once daily · started")
        XCTAssertEqual(sections.allergies.map(\.title), ["penicillin"])
        XCTAssertEqual(sections.plan.first?.title, "recheck in 3 months")

        // Evidence: the BP field cites "142/88" and its audio time.
        let bp = try XCTUnwrap(sections.vitals.first)
        XCTAssertEqual(bp.evidence, "142/88")
        XCTAssertEqual(bp.evidenceSentence, "BP 142/88, pulse 76.", "review L3 I2: the whole sentence is the evidence")
        let highlight = try XCTUnwrap(bp.highlight)
        XCTAssertEqual(
            (bp.evidenceSentence as NSString).substring(
                with: NSRange(location: highlight.lowerBound, length: highlight.count)),
            "142/88")
        let words = Self.words(Self.encounter)
        let bpIndex = try XCTUnwrap(words.firstIndex { $0.word.hasPrefix("142/88") })
        XCTAssertEqual(bp.field.span.wordStart, bpIndex)
        XCTAssertEqual(bp.seekMs, words[bpIndex].startMs)
        XCTAssertFalse(bp.field.reviewed, "every field starts as an unreviewed draft")

        let saved = await h.results.saved
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(saved.first?.fields.count, draft.fields.count)
    }

    func testClinicalTextNeverReachesAnEngineThatIsNotOnThisPhone() async throws {
        let cloud = RecordingStructureModel(locality: .cloud)
        let h = Harness(privacy: .clinical, choice: .needle, needle: cloud, needleAvailability: .ready)
        try await h.insertEncounter()
        do {
            _ = try await h.service.extractSOAP(transcriptionID: h.id)
            XCTFail("a cloud structure engine must be refused for clinical text")
        } catch let error as StructuredExtractionService.ExtractionError {
            guard case .privacyRoutingRefused = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(cloud.callCount, 0, "nothing was sent")
        // Even a trusted home-network host is refused for clinical structure extraction.
        let lan = EngineDescriptor(
            id: "x", kind: .structure, provider: "x", displayName: "x", locality: .localNetwork, license: "x")
        XCTAssertFalse(StructuredExtractionService.mayRun(lan, on: .clinical))
        XCTAssertTrue(StructuredExtractionService.mayRun(StubStructureModel().descriptor, on: .clinical))
    }

    func testNeedleChosenButUnavailableFallsBackToTheStubAndSaysSo() async throws {
        let h = Harness(choice: .needle, needle: RecordingStructureModel(locality: .onDevice))
        try await h.insertEncounter()
        let draft = try await h.service.extractSOAP(transcriptionID: h.id)
        XCTAssertTrue(draft.isStub)
        XCTAssertEqual(draft.fallbackReason, "Download Needle 3 first.")
    }

    func testLowConfidenceGoesToTheNeedsReviewBinAndStaysOutOfTheSOAPNotes() async throws {
        let weak = RecordingStructureModel(
            locality: .onDevice,
            reply: #"[{"name":"record_vital","arguments":{"kind":"BP","value_tag":"bp_1"}}]"#, confidence: 0.4)
        let h = Harness(choice: .needle, needle: weak, needleAvailability: .ready)
        try await h.insertEncounter()
        let draft = try await h.service.extractSOAP(transcriptionID: h.id)
        XCTAssertEqual(draft.run.modelSHA256, "fakehash")
        let sections = DraftSections(draft: draft)
        XCTAssertTrue(sections.draftItems.isEmpty)
        XCTAssertFalse(sections.needsReview.isEmpty)
        XCTAssertNil(SOAPDraftHandoff.notes(for: sections, engineName: "Needle 3"))
        XCTAssertGreaterThan(weak.callCount, 0)
        XCTAssertTrue(weak.receivedTexts.allSatisfy { !$0.contains("142/88") }, "the model only sees tags")
    }

    func testAnEngineFailureIsANeedsReviewItemNotASilentGap() async throws {
        let failing = RecordingStructureModel(locality: .onDevice, error: .noToolCall)
        let h = Harness(choice: .needle, needle: failing, needleAvailability: .ready)
        try await h.insertEncounter()
        let draft = try await h.service.extractSOAP(transcriptionID: h.id)
        let sections = DraftSections(draft: draft)
        XCTAssertEqual(sections.needsReview.count, draft.sentenceCount)
        XCTAssertEqual(sections.needsReview.first?.field.reviewReasons, ["The model gave no answer for this sentence."])
    }

    func testReviewingMovesAnItemIntoTheDraftAndTheHandoffIsOnDevice() async throws {
        let h = Harness()
        try await h.insertEncounter()
        let model = ExtractFieldsViewModel(service: h.service, transcriptionID: h.id)
        await model.extract()
        XCTAssertEqual(model.phase, .ready)
        XCTAssertTrue(model.engineBadge.hasPrefix("STUB"))
        XCTAssertNil(model.soapNotes, "review L3 I7: nothing reviewed yet, so nothing goes to the SOAP note")

        let item = try XCTUnwrap(model.sections?.medications.first)
        await model.toggleReviewed(item)
        XCTAssertEqual(model.sections?.medications.first?.field.reviewed, true)
        let notes = try XCTUnwrap(model.soapNotes)
        XCTAssertTrue(notes.contains("- lisinopril: 10 mg · PO · once daily · started"), notes)
        XCTAssertFalse(notes.contains("142/88"), "an unreviewed vital stays out: \(notes)")
        XCTAssertFalse(notes.contains("[unreviewed]"), notes)
        XCTAssertEqual(model.reviewedDraftCount, 1)
        let reviewed = await h.results.reviewedIDs
        XCTAssertEqual(reviewed, [item.id])

        XCTAssertEqual(SOAPDraftHandoff.modelChoice.locality, .onDevice)
        XCTAssertEqual(SOAPDraftHandoff.templateKey, BuiltInTemplates.soapNote.canonicalKey)
    }

    // MARK: - Review L3 I2, I6, I8

    func testTheEvidenceIsTheWholeSentenceSoTheDrugIsVisible() async throws {
        let h = Harness()
        try await h.insertEncounter("Lisinopril 10 mg and levothyroxine 50 mcg daily.")
        let draft = try await h.service.extractSOAP(transcriptionID: h.id)
        let sections = DraftSections(draft: draft)
        let items = sections.draftItems + sections.needsReview
        XCTAssertFalse(items.isEmpty)
        for item in items {
            XCTAssertEqual(item.evidenceSentence, "Lisinopril 10 mg and levothyroxine 50 mcg daily.")
        }
    }

    func testTheStubIsNeverConfidentOnClinicalFields() async throws {
        let tagged = NumericNormalizer.normalize("Considering starting metoprolol 25 mg.").tagged
        let output = try await StubStructureModel().extract(
            jsonSchema: StructureCatalog.soapMeds.toolsJSON, from: tagged, privacyClass: .clinical)
        XCTAssertLessThan(output.confidence, StructuredResultGate.defaultAct)
        XCTAssertEqual(StructuredCall.parseArray(output.json)?.first?.string("status"), "considering")

        // Even with the act threshold at its lowest setting, a STUB field is never "Confident".
        let h = Harness()
        var settings = h.settings.load()
        settings.actThreshold = 0.5
        settings.provisionalThreshold = 0.3
        h.settings.save(settings)
        try await h.insertEncounter()
        let draft = try await h.service.extractSOAP(transcriptionID: h.id)
        XCTAssertFalse(draft.fields.isEmpty)
        XCTAssertFalse(draft.fields.contains { $0.verdict == .act }, "\(draft.fields.map(\.verdict))")
    }

    func testTheStubReadsNegationBeforeADrug() {
        func calls(_ text: String) -> [StructuredCall] {
            StubStructureModel.soap(in: NumericNormalizer.normalize(text).tagged).map(\.0)
        }
        XCTAssertEqual(
            calls("No longer taking lisinopril 10 mg.").first { $0.name == "add_medication" }?.string("status"),
            "stopped", "re-review minor 4")
        for text in ["Denies taking aspirin.", "Not taking metformin.", "Never took ibuprofen."] {
            XCTAssertFalse(calls(text).contains { $0.name == "add_medication" }, text)
        }
        XCTAssertEqual(calls("Takes aspirin 81 mg daily.").first?.string("status"), "taking")
        XCTAssertEqual(
            calls("No fever, takes aspirin 81 mg daily.").first { $0.name == "add_medication" }?.string("status"),
            "taking")
    }

    func testAFieldThatFailedACheckNeedsItsReasonsSeenAndCanBeEdited() async throws {
        let wrong = RecordingStructureModel(
            locality: .onDevice,
            reply:
                #"[{"name":"add_medication","arguments":{"drug":"lisinopril","dose_tag":"dose_9","status":"started"}}]"#,
            confidence: 0.95)
        let h = Harness(choice: .needle, needle: wrong, needleAvailability: .ready)
        try await h.insertEncounter("Started lisinopril 10 mg by mouth once daily.")
        let model = ExtractFieldsViewModel(service: h.service, transcriptionID: h.id)
        await model.extract()
        let item = try XCTUnwrap(model.sections?.needsReview.first { $0.title == "lisinopril" })
        XCTAssertFalse(item.field.reviewReasons.isEmpty)

        await model.toggleReviewed(item)
        XCTAssertEqual(
            model.draft?.fields.first { $0.id == item.id }?.reviewed, false, "one tap cannot accept a failed check")
        XCTAssertEqual(model.reviewRequest?.id, item.id, "the reasons are shown first")
        XCTAssertEqual(item.editableFields.map(\.key), ["drug", "dose", "route", "frequency", "status"])

        await model.confirmReview(item, edits: ["dose": "10 mg"])
        XCTAssertNil(model.reviewRequest)
        let reviewed = try XCTUnwrap(model.sections?.medications.first { $0.id == item.id })
        XCTAssertTrue(reviewed.field.reviewed)
        XCTAssertTrue(reviewed.isEdited)
        XCTAssertTrue(reviewed.detail.hasPrefix("10 mg"), reviewed.detail)
        XCTAssertEqual(reviewed.field.reviewReasons, item.field.reviewReasons, "the reasons travel with the field")
        let notes = try XCTUnwrap(model.soapNotes)
        XCTAssertTrue(notes.contains("- lisinopril: 10 mg"), notes)
        XCTAssertTrue(notes.contains("edited in review"), notes)
        XCTAssertTrue(notes.contains("does not match any number"), notes)
        let saved = await h.results.reviewedArguments[item.id]
        XCTAssertTrue(saved?.contains("10 mg") ?? false, saved ?? "nil")
    }

    func testAcceptingAFailedCheckWithoutAnEditSaysSoInTheHandoff() async throws {
        let wrong = RecordingStructureModel(
            locality: .onDevice, reply: #"[{"name":"record_vital","arguments":{"kind":"HR","value_tag":"rate_1"}}]"#,
            confidence: 0.95)
        let h = Harness(choice: .needle, needle: wrong, needleAvailability: .ready)
        try await h.insertEncounter("Heart rate 300.")
        let model = ExtractFieldsViewModel(service: h.service, transcriptionID: h.id)
        await model.extract()
        let item = try XCTUnwrap(model.sections?.needsReview.first)
        await model.confirmReview(item, edits: [:])
        let notes = try XCTUnwrap(model.soapNotes)
        XCTAssertTrue(notes.contains("- HR: 300/min (accepted in review despite: Heart rate 300 is outside"), notes)
    }

    // MARK: - Re-review N1: a correction said in the next sentence

    func testTheCorrectionCueListIsNamedAndCoversEveryInSentenceCue() {
        for cue in [
            "sorry", "i mean", "correction", "no wait", "actually", "rather", "make that", "scratch that", "strike that",
        ] {
            XCTAssertTrue(CrossSentenceCorrection.cues.contains(cue), cue)
        }
        XCTAssertTrue(SentenceNeighbours.correctionWords.isSubset(of: Set(CrossSentenceCorrection.cues)))
        XCTAssertTrue(SentenceNeighbours.correctionPairs.isSubset(of: Set(CrossSentenceCorrection.cues)))
        let cases: [(String, String?)] = [
            ("Sorry, 25 micrograms.", "sorry"), ("No, 25 micrograms.", "no"), ("No wait, the right knee.", "no wait"),
            ("I mean the right knee.", "i mean"), ("Actually, the right knee.", "actually"),
            ("Make that 25 micrograms.", "make that"), ("Scratch that.", "scratch that"),
            ("Correction: 25 micrograms.", "correction"), ("No.", nil), ("No fever today.", nil),
            ("Patient resting comfortably.", nil),
        ]
        for (sentence, cue) in cases {
            XCTAssertEqual(CrossSentenceCorrection.cue(in: sentence), cue, sentence)
        }
    }

    func testACorrectionInTheNextSentenceSendsThePreviousFieldsToReview() async throws {
        let h = Harness()
        try await h.insertEncounter("Gave fentanyl 50 micrograms IV. Sorry, 25 micrograms.")
        let draft = try await h.service.extractSOAP(transcriptionID: h.id)
        let sections = DraftSections(draft: draft)
        XCTAssertTrue(sections.medications.isEmpty, "never a clean fentanyl 50 mcg")
        let fentanyl = try XCTUnwrap(sections.needsReview.first { $0.title == "fentanyl" })
        XCTAssertTrue(fentanyl.detail.hasPrefix("50 mcg"), "the restated dose is never applied: \(fentanyl.detail)")
        XCTAssertTrue(
            fentanyl.field.reviewReasons.contains { $0.hasPrefix("Corrected in the next sentence") },
            "\(fentanyl.field.reviewReasons)")
        XCTAssertTrue(fentanyl.field.reviewReasons.contains { $0.contains("25 mcg") }, "\(fentanyl.field.reviewReasons)")
        XCTAssertTrue(fentanyl.needsReviewSheet, "one tap cannot accept it")

        let side = Harness()
        try await side.insertEncounter("Complains of pain in the left knee. Actually, the right knee.")
        let problems = DraftSections(draft: try await side.service.extractSOAP(transcriptionID: side.id))
        XCTAssertTrue(problems.problems.isEmpty, "a wrong-side problem never passes clean")
        XCTAssertTrue(
            problems.needsReview.contains { $0.field.reviewReasons.contains { $0.contains("Corrected in the next") } })
    }

    func testASentenceWithoutACueLeavesThePreviousFieldsAlone() async throws {
        let h = Harness()
        try await h.insertEncounter("Gave fentanyl 50 micrograms IV. Patient resting comfortably.")
        let sections = DraftSections(draft: try await h.service.extractSOAP(transcriptionID: h.id))
        XCTAssertEqual(sections.medications.map(\.title), ["fentanyl"])
    }

    func testTheEvalAppliesTheSameCrossSentenceRule() async throws {
        let set = SOAPEvalSet(
            id: "t", version: 1, catalog: "soap-meds.v1",
            cases: [
                SOAPEvalCase(
                    id: "c", title: "synthetic",
                    sentences: [
                        SOAPEvalSentence(
                            text: "Gave fentanyl 50 micrograms IV.",
                            expected: [ExpectedCall(name: "add_medication", arguments: ["drug": "fentanyl"])]),
                        SOAPEvalSentence(text: "Sorry, 25 micrograms.", expected: []),
                    ])
            ])
        let result = await StructureEvalRunner(engine: StubStructureModel(), gate: StructuredResultGate())
            .run(soap: set, commands: CommandEvalSet(id: "t", version: 1, catalog: "dictation-commands.v1", utterances: []))
        let first = try XCTUnwrap(result.soap.scores.first)
        XCTAssertTrue(first.predicted.filter { $0.name != "none" }.allSatisfy { $0.verdict == .needsReview })
    }

    // MARK: - Review L3 I10: Needle is labelled experimental where it is used

    func testNeedleIsLabelledExperimentalWithItsEvalNumbers() async throws {
        XCTAssertTrue(NeedleExperimental.isExperimental)
        XCTAssertTrue(NeedleExperimental.chip.hasPrefix("Experimental"))
        XCTAssertTrue(NeedleExperimental.chip.contains("%"), NeedleExperimental.chip)

        let settings = StructureSettingsViewModel(
            store: InMemoryStructureSettingsStore(), needleAssets: nil, needleInBuild: true, notInBuildMessage: "x",
            needleDownloadBytes: nil, needleModelSHA256: nil)
        XCTAssertTrue(settings.engineCaption.contains("Experimental"), settings.engineCaption)

        let answered = RecordingStructureModel(
            locality: .onDevice, reply: #"[{"name":"record_vital","arguments":{"kind":"BP","value_tag":"bp_1"}}]"#)
        let h = Harness(choice: .needle, needle: answered, needleAvailability: .ready)
        try await h.insertEncounter()
        let model = ExtractFieldsViewModel(service: h.service, transcriptionID: h.id)
        await model.extract()
        XCTAssertTrue(model.engineBadge.contains("Experimental"), model.engineBadge)
        XCTAssertTrue(ExtractFieldsViewModel.menuTitle.contains("experimental"))
    }

    func testTheSOAPRunOfAClinicalItemRoutesToTheOnDeviceModelWithoutAConfirmation() async throws {
        let h = Harness(privacy: .clinical)
        try await h.insertEncounter()
        let deliverables = FakeDeliverableStore()
        let service = DeliverableService(
            transcripts: h.store, deliverables: deliverables, routingPolicy: { PrivacyRoutingPolicy() })
        try await service.installBuiltInTemplates()
        let onDevice = RecordingLanguageModel(locality: .onDevice)
        let decision = try await service.route(
            transcriptionID: h.id, templateID: BuiltInTemplates.soapNote.id, model: onDevice)
        guard case .allowed(let route) = decision else { return XCTFail("\(decision)") }
        XCTAssertEqual(route.locality, .onDevice)
        XCTAssertEqual(route.privacyClass, .clinical)
    }
}

// MARK: - Fakes

actor FakeStructuredResultStore: StructuredResultStoring {
    private(set) var saved: [(run: StructuredRun, fields: [StructuredField])] = []
    private(set) var reviewedIDs: [UUID] = []
    private(set) var reviewedArguments: [UUID: String] = [:]
    private(set) var evals: [StructuredEvalRun] = []

    func save(_ run: StructuredRun, fields: [StructuredField]) async throws { saved.append((run, fields)) }
    func runs(forTranscription id: UUID) async throws -> [StructuredRun] {
        saved.map(\.run).filter { $0.transcriptionID == id }.reversed()
    }
    func fields(forRun id: UUID) async throws -> [StructuredField] {
        saved.first { $0.run.id == id }?.fields ?? []
    }
    func setReviewed(fieldID: UUID, reviewed: Bool, argumentsJSON: String?) async throws {
        if reviewed { reviewedIDs.append(fieldID) }
        if let argumentsJSON { reviewedArguments[fieldID] = argumentsJSON }
    }
    func saveEvalRun(_ run: StructuredEvalRun) async throws { evals.append(run) }
    func evalRuns() async throws -> [StructuredEvalRun] { evals }
}

/// A structure engine that records what it was sent and answers from a script.
final class RecordingStructureModel: StructureModel, @unchecked Sendable {
    let descriptor: EngineDescriptor
    private let lock = NSLock()
    private let reply: String
    private let confidence: Double
    private let error: StructureModelError?
    private var texts: [String] = []

    init(
        locality: EngineLocality, reply: String = "[]", confidence: Double = 0.9, error: StructureModelError? = nil
    ) {
        descriptor = EngineDescriptor(
            id: "needle.needle3", kind: .structure, provider: "Fake", displayName: "Needle 3", locality: locality,
            license: "Test")
        self.reply = reply
        self.confidence = confidence
        self.error = error
    }

    var callCount: Int { lock.withLock { texts.count } }
    var receivedTexts: [String] { lock.withLock { texts } }

    func extract(jsonSchema: String, from text: String, privacyClass: PrivacyClass) async throws -> StructuredOutput {
        lock.withLock { texts.append(text) }
        if let error { throw error }
        return StructuredOutput(json: reply, confidence: confidence, modelSHA256: "fakehash")
    }

    func embed(_ text: String) async throws -> [Float] { [] }
}
