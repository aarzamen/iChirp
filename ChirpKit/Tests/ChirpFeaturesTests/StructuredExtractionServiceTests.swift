import ChirpCore
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

        func insertEncounter() async throws {
            var row = Transcription(id: id, sourceType: .dictation, fileName: "Synthetic.wav", status: .completed)
            row.rawTranscript = StructuredExtractionServiceTests.encounter
            row.wordTimestamps = StructuredExtractionServiceTests.words(StructuredExtractionServiceTests.encounter)
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
        let notes = try XCTUnwrap(model.soapNotes)
        XCTAssertTrue(notes.contains("lisinopril: 10 mg · PO · once daily · started [unreviewed]"), notes)

        let item = try XCTUnwrap(model.sections?.medications.first)
        await model.toggleReviewed(item)
        XCTAssertEqual(model.sections?.medications.first?.field.reviewed, true)
        XCTAssertTrue(model.soapNotes?.contains("lisinopril: 10 mg · PO · once daily · started\n") ?? false)
        let reviewed = await h.results.reviewedIDs
        XCTAssertEqual(reviewed, [item.id])

        XCTAssertEqual(SOAPDraftHandoff.modelChoice.locality, .onDevice)
        XCTAssertEqual(SOAPDraftHandoff.templateKey, BuiltInTemplates.soapNote.canonicalKey)
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
