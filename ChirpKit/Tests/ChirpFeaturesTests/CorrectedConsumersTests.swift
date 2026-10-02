import ChirpCore
import ChirpText
import Foundation
import XCTest

@testable import ChirpFeatures

/// Plan 025 Step A7: every ChirpFeatures consumer reads the corrected text through the one accessor — the Transcript
/// screen's model, Copy, Extract fields (with the stale-run rule), Jev, model input and Create's voice message.
/// Synthetic content only.
@MainActor
final class CorrectedConsumersTests: XCTestCase {
    /// "Patient takes met for men 500 mg daily. Recheck in two weeks." (one line, no speakers).
    nonisolated static let heardText = "Patient takes met for men 500 mg daily. Recheck in two weeks."
    nonisolated static let correctedText = "Patient takes metformin 500 mg daily. Recheck in two weeks."

    nonisolated static func row(
        clean: String? = nil, words: Bool = true, source: Transcription.SourceType = .file,
        privacy: PrivacyClass = .personal
    ) -> Transcription {
        var row = Transcription(
            sourceType: source, fileName: "Synthetic visit.m4a", status: .completed, privacyClass: privacy)
        if words {
            row.wordTimestamps = heardText.split(separator: " ").enumerated().map { index, word in
                WordTimestamp(word: String(word), startMs: index * 400, endMs: index * 400 + 350, confidence: 0.9)
            }
            row.transcriptSegments = FileTranscriptSegments.materialize(words: row.wordTimestamps ?? [])
        }
        row.rawTranscript = heardText
        row.cleanTranscript = clean
        return row
    }

    /// The row with "met for men" corrected to "metformin", made through the one writer.
    private func corrected(_ row: Transcription, store: FakeStore) async throws -> Transcription {
        let outcome = try await TranscriptCorrectionService(store: store, context: { .none }).correct(
            row.id, line: 0, in: row.text(.heard), baseline: row.wordsFingerprint, text: Self.correctedText)
        return outcome.row
    }

    private func viewModel(
        _ store: FakeStore, _ row: Transcription, mode: CleanupMode = .raw, service: Bool = true,
        context: TranscriptTextContext = .none
    ) -> TranscriptViewModel {
        var settings = TranscriptionSettings()
        settings.cleanupMode = mode
        return TranscriptViewModel(
            id: row.id, store: store, paths: AppPaths(root: FileManager.default.temporaryDirectory),
            settings: InMemorySettingsStore(settings),
            corrections: service ? TranscriptCorrectionService(store: store, context: { context }) : nil,
            textContext: { context })
    }

    // MARK: - Transcript screen

    func testCorrectedLineShowsTheCorrection() async throws {
        let row = Self.row()
        let store = FakeStore(rows: [row])
        let model = viewModel(store, row)
        await model.load()
        let outcome = try await model.correct(line: 0, text: Self.correctedText)
        XCTAssertEqual(outcome.created.count, 1)
        XCTAssertEqual(model.paragraphs.map(\.text), [Self.correctedText])
        XCTAssertEqual(model.lines.map(\.text), [Self.correctedText])
        XCTAssertEqual(model.corrections.map(\.text), ["metformin"])
        XCTAssertEqual(model.corrections(inLine: 0).map(\.heard), ["met for men"])
        XCTAssertEqual(model.heardText(line: 0), Self.heardText)
        XCTAssertNotNil(model.correctionsChangedAt)
        // A fresh screen reads it back from the store.
        let reopened = viewModel(store, row)
        await reopened.load()
        XCTAssertEqual(reopened.paragraphs.map(\.text), [Self.correctedText])
    }

    func testPlainTextIncludesCorrectionsInRawAndClean() async throws {
        let row = Self.row(clean: "Patient takes met for men 500 mg daily. Recheck in 2 weeks.")
        let store = FakeStore(rows: [row])
        _ = try await corrected(row, store: store)
        let context = TranscriptTextContext(customWords: [CustomWord(word: "two weeks", replacement: "2 weeks")])
        let raw = viewModel(store, row, mode: .raw, context: context)
        await raw.load()
        XCTAssertEqual(raw.plainText, Self.correctedText)
        let clean = viewModel(store, row, mode: .clean, context: context)
        await clean.load()
        XCTAssertEqual(clean.plainText, "Patient takes metformin 500 mg daily. Recheck in 2 weeks.")
    }

    func testCanCorrectIsFalseWithoutWordTimings() async throws {
        let untimed = Self.row(words: false)
        let timed = Self.row()
        let store = FakeStore(rows: [untimed, timed])
        let untimedModel = viewModel(store, untimed)
        await untimedModel.load()
        XCTAssertFalse(untimedModel.canCorrect)
        XCTAssertFalse(untimedModel.hasWordTimings)
        let readOnly = viewModel(store, timed, service: false)
        await readOnly.load()
        XCTAssertFalse(readOnly.canCorrect)
        let timedModel = viewModel(store, timed)
        await timedModel.load()
        XCTAssertTrue(timedModel.canCorrect)
        XCTAssertTrue(timedModel.hasWordTimings)
    }

    func testRevertLineAndUndo() async throws {
        let row = Self.row()
        let store = FakeStore(rows: [row])
        let model = viewModel(store, row)
        await model.load()
        try await model.correct(line: 0, text: Self.correctedText)
        let reverted = try await model.revertLine(0)
        XCTAssertEqual(model.paragraphs.map(\.text), [Self.heardText])
        XCTAssertEqual(model.corrections, [])
        try await model.undo(reverted.undo)
        XCTAssertEqual(model.paragraphs.map(\.text), [Self.correctedText])
        try await model.revertAll()
        XCTAssertEqual(model.paragraphs.map(\.text), [Self.heardText])
    }

    // MARK: - Extract fields

    func testSourceTextUsesCorrections() async throws {
        let row = Self.row()
        let store = FakeStore(rows: [row])
        let item = try await corrected(row, store: store)
        let source = StructuredSourceText(transcription: item)
        XCTAssertEqual(source.text, Self.correctedText)
        XCTAssertFalse(source.text.contains("met for men"))
    }

    func testSpanOverACorrectionCoversItsWords() async throws {
        let row = Self.row()
        let store = FakeStore(rows: [row])
        let source = StructuredSourceText(transcription: try await corrected(row, store: store))
        let start = (source.text as NSString).range(of: "metformin 500").location
        let span = source.span(for: start..<(start + 13))
        XCTAssertEqual(span.wordStart, 2)
        XCTAssertEqual(span.wordEnd, 6, "metformin stands for 'met for men' (words 2–4), then '500' (word 5)")
        XCTAssertEqual(span.startMs, 800)
        XCTAssertEqual(span.endMs, 5 * 400 + 350)
    }

    private func extraction(_ store: FakeStore) -> StructuredExtractionService {
        StructuredExtractionService(
            transcripts: store, results: FakeStructuredResultStore(),
            settings: InMemoryStructureSettingsStore(StructureSettings()),
            engines: StructureEngines(needle: nil, needleAvailability: { .unavailable("Synthetic.") }),
            deliverables: FakeDeliverableStore())
    }

    func testDraftIsStaleAfterACorrectionAndNotBefore() async throws {
        let row = Self.row(source: .dictation)
        let store = FakeStore(rows: [row])
        let service = extraction(store)
        _ = try await service.extractSOAP(transcriptionID: row.id)
        let fresh = try await service.latestDraft(transcriptionID: row.id)
        XCTAssertEqual(fresh?.sourceChanged, false)
        _ = try await corrected(row, store: store)
        let stale = try await service.latestDraft(transcriptionID: row.id)
        XCTAssertEqual(stale?.sourceChanged, true)
        // Extracting again clears it.
        _ = try await service.extractSOAP(transcriptionID: row.id)
        let again = try await service.latestDraft(transcriptionID: row.id)
        XCTAssertEqual(again?.sourceChanged, false)
    }

    func testStaleDraftHidesEvidenceAndBlocksSOAPHandOff() async throws {
        let row = Self.row(source: .dictation)
        let store = FakeStore(rows: [row])
        let service = extraction(store)
        let model = ExtractFieldsViewModel(service: service, transcriptionID: row.id)
        await model.extract()
        let item = try XCTUnwrap(model.sections?.draftItems.first { !$0.needsReviewSheet })
        await model.toggleReviewed(item)
        XCTAssertNotNil(model.soapNotes)
        XCTAssertFalse(model.isStale)
        XCTAssertNil(model.soapHandOffBlockedReason)

        _ = try await corrected(row, store: store)
        let reopened = ExtractFieldsViewModel(service: service, transcriptionID: row.id)
        await reopened.load()
        XCTAssertTrue(reopened.isStale)
        XCTAssertNil(reopened.soapNotes, "a stale run never reaches the SOAP note")
        XCTAssertEqual(reopened.soapHandOffBlockedReason, "Extract again first.")
        let items = (reopened.sections?.draftItems ?? []) + (reopened.sections?.needsReview ?? [])
        XCTAssertFalse(items.isEmpty)
        XCTAssertTrue(items.allSatisfy { $0.evidence.isEmpty && $0.evidenceSentence.isEmpty }, "no stale quote shown")
    }

    // MARK: - Jev, model input, Create

    func testJevExcerptUsesCorrectedText() async throws {
        let row = Self.row()
        let store = FakeStore(rows: [row])
        let item = try await corrected(row, store: store)
        let shown = DecisionInputWindow.text(of: item, mode: .raw)
        XCTAssertEqual(DecisionInputWindow.excerpt(shown.plainText), Self.correctedText)
        XCTAssertEqual(DecisionInputWindow.paragraphExcerpt(shown.lines).text.contains("metformin"), true)
    }

    func testTemplateSourceContainsCorrection() async throws {
        // A clinical item on the on-device model: routing is unchanged; the model reads the corrected words.
        let row = Self.row(privacy: .clinical)
        let store = FakeStore(rows: [row])
        _ = try await corrected(row, store: store)
        let deliverables = FakeDeliverableStore()
        try await deliverables.installBuiltInTemplates(BuiltInTemplates.all)
        let service = DeliverableService(
            transcripts: store, deliverables: deliverables, routingPolicy: { PrivacyRoutingPolicy() })
        let model = Destination.onDevice.makeModel()
        model.script([.text("Summary.")])
        for try await _ in service.generate(
            templateID: BuiltInTemplates.summary.id, transcriptionID: row.id, model: model)
        {}
        XCTAssertTrue(model.everythingReceived.contains("Patient takes metformin 500 mg daily."))
        XCTAssertFalse(model.everythingReceived.contains("met for men"))
    }

    func testVoiceMessageTextUsesCorrections() async throws {
        let harness = try await CreateHarness()
        let row = Self.row(source: .dictation)
        try await harness.transcripts.insert(row)
        _ = try await corrected(row, store: harness.transcripts)
        harness.speechOutcome = .saved(row.id)
        let flow = harness.makeFlow()
        await flow.start(
            CreateRequest(input: .speak, output: .voiceMessage(summarizeFirst: false)),
            makeModel: { RecordingLanguageModel(locality: .onDevice) })
        let request = try XCTUnwrap(harness.voices.first?.requests.first)
        XCTAssertTrue(request.text.contains("metformin"), request.text)
        XCTAssertFalse(request.text.contains("met for men"))
    }
}
