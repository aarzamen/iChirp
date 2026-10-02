import ChirpCore
import ChirpFeatures
import ChirpStore
import ChirpText
import SwiftUI
import XCTest

@testable import iChirp

/// Plan 025 Step A8: the Transcript screen's correction marks and the words of its correction sheets, without the GUI.
/// Synthetic content only.
@MainActor
final class TranscriptCorrectionsAppTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 790_000_000)

    private func row(_ text: String = "The patient takes met for men daily. She feels well today.") -> Transcription {
        var row = Transcription(fileName: "synthetic.m4a", status: .completed)
        row.wordTimestamps = text.split(separator: " ").enumerated().map { index, word in
            WordTimestamp(word: String(word), startMs: index * 300, endMs: index * 300 + 250, confidence: 0.9)
        }
        row.rawTranscript = text
        return row
    }

    private func corrected(_ row: Transcription, _ adds: [(Range<Int>, String)]) throws -> Transcription {
        var row = row
        _ = try row.applyCorrections(
            TranscriptCorrectionPlan(
                add: adds.map {
                    TranscriptCorrection(
                        wordRange: $0.0, heard: "", text: $0.1, origin: .edit, createdAt: now, updatedAt: now)
                }), now: now)
        return row
    }

    /// The substrings of `text` that carry an underline.
    private func underlined(_ text: AttributedString) -> [String] {
        text.runs.compactMap { run in
            run.underlineStyle == nil ? nil : String(text[run.range].characters)
        }
    }

    func testCorrectedRangesGetADottedUnderlineAndNothingElseDoes() throws {
        let item = try corrected(row(), [(3..<6, "metformin"), (9..<10, "great")])
        let heard = item.text(.heard)
        let line = try XCTUnwrap(heard.lines.first)
        let attributed = TranscriptLineText.attributed(line, tokens: heard.tokens)
        XCTAssertEqual(String(attributed.characters), "The patient takes metformin daily. She feels great today.")
        XCTAssertEqual(underlined(attributed), ["metformin", "great"])
        XCTAssertEqual(TranscriptLineText.correctionCount(in: line, tokens: heard.tokens), 2)
        // Every other run carries no style at all.
        for run in attributed.runs where run.underlineStyle == nil {
            XCTAssertNil(run.foregroundColor)
            XCTAssertNil(run.backgroundColor)
        }
    }

    func testLineWithoutCorrectionsRendersPlainText() throws {
        let heard = row().text(.heard)
        let line = try XCTUnwrap(heard.lines.first)
        let attributed = TranscriptLineText.attributed(line, tokens: heard.tokens)
        XCTAssertEqual(attributed, AttributedString(line.text))
        XCTAssertEqual(TranscriptLineText.correctionCount(in: line, tokens: heard.tokens), 0)
    }

    func testUnicodeCorrectionsUnderlineWholeCharacters() throws {
        let item = try corrected(row("café naïve 🙂 我爱你 end."), [(2..<3, "👍🏽"), (3..<4, "我恨你")])
        let heard = item.text(.heard)
        let attributed = TranscriptLineText.attributed(try XCTUnwrap(heard.lines.first), tokens: heard.tokens)
        XCTAssertEqual(underlined(attributed), ["👍🏽", "我恨你"])
    }

    func testCorrectionsMenuTitleCountsCorrections() {
        XCTAssertNil(TranscriptCorrectionsCopy.menuTitle(applied: 0, detached: 0))
        XCTAssertEqual(TranscriptCorrectionsCopy.menuTitle(applied: 1, detached: 0), "Corrections (1)…")
        XCTAssertEqual(TranscriptCorrectionsCopy.menuTitle(applied: 14, detached: 3), "Corrections (14)…")
        // Fix round 1 (M6): only corrections kept from an earlier transcript: never "Corrections (0)".
        XCTAssertEqual(TranscriptCorrectionsCopy.menuTitle(applied: 0, detached: 2), "Earlier corrections (2)…")
    }

    /// Fix round 1 (M9): a Replace all's corrections are one row that names their count and reverts together; other
    /// corrections stay one row each, in time order.
    func testABatchIsOneRowThatRevertsTogether() throws {
        let batch = UUID()
        func item(_ range: Range<Int>, _ text: String, _ origin: TranscriptCorrection.Origin, _ batchID: UUID?)
            -> TranscriptCorrection
        {
            TranscriptCorrection(
                wordRange: range, heard: "", text: text, origin: origin, batchID: batchID, createdAt: now,
                updatedAt: now)
        }
        let items = [
            item(0..<1, "A", .edit, nil), item(3..<6, "metformin", .replaceAll, batch),
            item(7..<8, "B", .edit, nil), item(9..<10, "metformin", .replaceAll, batch),
        ]
        let groups = CorrectionsSheet.groups(items)
        XCTAssertEqual(groups.map(\.items.count), [1, 2, 1])
        XCTAssertEqual(groups[1].items.map(\.range), [3..<6, 9..<10])
        XCTAssertEqual(
            TranscriptCorrectionsCopy.originTitle(groups[1].items[0].origin, batchCount: groups[1].items.count),
            "Replace all · 2")
    }

    // MARK: - Show Original and Undo (fix round 1)

    private let visit = "The patient takes met for men 500 mg twice daily. Blood pressure was 128 over 82 today."

    /// I2: Show Original resolves its line from the transcript as it is now, so after reverting one of two
    /// corrections the heard line is whole; with none left there is nothing to show (the sheet closes).
    func testShowOriginalResolvesTheLineAfterAPartialRevert() throws {
        var item = try corrected(row(visit), [(3..<6, "metformin"), (13..<14, "138")])
        let first = try XCTUnwrap(item.textCorrections?.items.first)
        _ = try item.applyCorrections(TranscriptCorrectionPlan(remove: [first.id]), now: now)
        let passage = try XCTUnwrap(PassageOriginalSheet.passage(lineID: 0, in: item.text(.heard)))
        XCTAssertEqual(passage.corrections.map(\.text), ["138"])
        let heardLine = PassageOriginalSheet.heardLine(
            passage.line, tokens: item.text(.heard).tokens, corrections: passage.corrections)
        XCTAssertEqual(String(heardLine.characters), visit, "the whole line as heard, through \"82 today.\"")

        let rest = try XCTUnwrap(item.textCorrections?.items.first)
        _ = try item.applyCorrections(TranscriptCorrectionPlan(remove: [rest.id]), now: now)
        XCTAssertNil(PassageOriginalSheet.passage(lineID: 0, in: item.text(.heard)))
    }

    private func screenModel() async throws -> (TranscriptViewModel, UUID) {
        let store = GRDBTranscriptionStore(database: try DatabaseManager.inMemory())
        let item = row(visit)
        try await store.insert(item)
        let model = TranscriptViewModel(
            id: item.id, store: store, paths: AppPaths(root: FileManager.default.temporaryDirectory),
            settings: InMemoryTestSettings(), corrections: TranscriptCorrectionService(store: store, context: { .none })
        )
        await model.load()
        try await model.correct(
            line: 0, text: "The patient takes metformin 500 mg twice daily. Blood pressure was 138 over 82 today.")
        return (model, item.id)
    }

    /// M9: revert, then Undo, restores exactly the corrections there were; M5: a second revert inside the window is
    /// undone with the first.
    func testUndoAfterRevertsRestoresTheSameCorrections() async throws {
        let (model, _) = try await screenModel()
        let before = model.corrections
        XCTAssertEqual(before.count, 2)
        let undo = CorrectionUndoController()
        await undo.revert([before[0].id], model: model)
        await undo.revert([before[1].id], model: model)
        XCTAssertEqual(model.corrections, [])
        XCTAssertNotNil(undo.offer)
        await undo.undo(model: model)
        XCTAssertEqual(model.corrections, before)
        XCTAssertNil(undo.offer)
        XCTAssertNil(undo.error)
    }

    /// M5: an Undo that cannot run says why in plain words and keeps the offer, so it can be tried again.
    func testAnUndoThatCannotRunSaysWhyAndKeepsTheOffer() async throws {
        let (model, _) = try await screenModel()
        let first = try XCTUnwrap(model.corrections.first)
        let undo = CorrectionUndoController()
        await undo.revert([first.id], model: model)
        // The same words are corrected again, differently and wider, before Undo.
        try await model.correct(
            line: 0, text: "The patient takes metformin XR twice daily. Blood pressure was 138 over 82 today.")
        await undo.undo(model: model)
        XCTAssertEqual(undo.error, "Those words were corrected again, so this can’t be undone.")
        XCTAssertNotNil(undo.offer, "the offer stays for another try")
    }

    /// M7: the "Made before your corrections" badge needs corrections that are still there.
    func testTheMadeBeforeBadgeNeedsCorrectionsLeft() async throws {
        let (model, _) = try await screenModel()
        XCTAssertNotNil(MadeBeforeCorrections.changedAt(of: model))
        try await model.revertAll()
        XCTAssertNil(MadeBeforeCorrections.changedAt(of: model))
    }

    func testMadeBeforeCorrectionsTagRule() {
        let changed = Date(timeIntervalSinceReferenceDate: 800_000_000)
        XCTAssertTrue(MadeBeforeCorrections.applies(documentCreatedAt: changed - 1, correctionsChangedAt: changed))
        XCTAssertFalse(MadeBeforeCorrections.applies(documentCreatedAt: changed + 1, correctionsChangedAt: changed))
        XCTAssertFalse(MadeBeforeCorrections.applies(documentCreatedAt: changed, correctionsChangedAt: changed))
        XCTAssertFalse(MadeBeforeCorrections.applies(documentCreatedAt: changed - 1, correctionsChangedAt: nil))
    }

    func testThePassageLineNamesSpeakerAndTimes() {
        XCTAssertEqual(
            TranscriptCorrectionsCopy.passageLine(speaker: "Speaker 1", startMs: 252_000, endMs: 271_000),
            "Speaker 1 · 04:12 – 04:31")
        XCTAssertEqual(TranscriptCorrectionsCopy.passageLine(speaker: nil, startMs: 0, endMs: 3_000), "00:00 – 00:03")
    }
}

/// Settings for the screen model in these tests (Raw clean-up, the defaults).
final class InMemoryTestSettings: SettingsStoring, @unchecked Sendable {
    // @unchecked Sendable: read-only after init.
    private let value = TranscriptionSettings()
    func load() -> TranscriptionSettings { value }
    func save(_ settings: TranscriptionSettings) {}
}
