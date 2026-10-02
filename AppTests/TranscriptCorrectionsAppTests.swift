import ChirpCore
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
        XCTAssertEqual(TranscriptCorrectionsCopy.menuTitle(applied: 14, detached: 0), "Corrections (14)…")
        XCTAssertEqual(
            TranscriptCorrectionsCopy.menuTitle(applied: 0, detached: 2), "Corrections (0)…",
            "corrections kept from an earlier transcript are still reachable")
    }

    func testRevertAllDialogCopyNamesTheCount() {
        XCTAssertEqual(TranscriptCorrectionsCopy.revertAllTitle(count: 14), "Revert all 14 corrections?")
        XCTAssertEqual(TranscriptCorrectionsCopy.revertAllTitle(count: 1), "Revert the correction?")
        XCTAssertEqual(
            TranscriptCorrectionsCopy.revertAllMessage,
            "The transcript goes back to the words Parakeet heard. Documents already made from it don’t change.")
    }

    func testOriginNamesAndBatches() {
        XCTAssertEqual(TranscriptCorrectionsCopy.originTitle(.edit, batchCount: 1), "Corrected")
        XCTAssertEqual(TranscriptCorrectionsCopy.originTitle(.replace, batchCount: 1), "Replaced")
        XCTAssertEqual(TranscriptCorrectionsCopy.originTitle(.replaceAll, batchCount: 12), "Replace all · 12")
        XCTAssertEqual(TranscriptCorrectionsCopy.originTitle(.rule, batchCount: 1), "Rule")
        XCTAssertEqual(TranscriptCorrectionsCopy.originTitle(.voiceCommand, batchCount: 2), "Voice command")
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
