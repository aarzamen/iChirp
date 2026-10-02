import ChirpCore
import ChirpFeatures
import ChirpText
import ChirpUI
import SwiftUI
import XCTest

@testable import iChirp

/// Plan 025 Step B5: the Transcript screen's find highlights and the words of the find bar, Replace All and the rule
/// offer, without the GUI. Synthetic content only.
@MainActor
final class TranscriptFindAppTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 790_000_000)

    private func row(_ text: String = "The patient takes met for men daily. Met for men again.") -> Transcription {
        var row = Transcription(fileName: "synthetic.m4a", status: .completed)
        row.wordTimestamps = text.split(separator: " ").enumerated().map { index, word in
            WordTimestamp(word: String(word), startMs: index * 300, endMs: index * 300 + 250, confidence: 0.9)
        }
        row.rawTranscript = text
        return row
    }

    /// The substrings of `text` whose background is `color`.
    private func filled(_ text: AttributedString, _ color: Color) -> [String] {
        text.runs.compactMap { run in
            run.backgroundColor == color ? String(text[run.range].characters) : nil
        }
    }

    private func marks(_ line: TranscriptTextLine, query: String, current: Int) -> TranscriptLineText.FindMarks {
        let matches = TranscriptSearchIndex(blocks: [line.text]).matches(for: query).map(\.range)
        return TranscriptLineText.FindMarks(matches: matches, current: matches[current])
    }

    func testMatchesGetMatchFillAndCurrentGetsCurrentFill() throws {
        let heard = row().text(.heard)
        let line = try XCTUnwrap(heard.lines.first)
        let attributed = TranscriptLineText.attributed(
            line, tokens: heard.tokens, find: marks(line, query: "met for men", current: 1))
        XCTAssertEqual(String(attributed.characters), line.text, "highlighting never changes the text")
        XCTAssertEqual(filled(attributed, Tokens.Color.findMatchFill), ["met for men"])
        XCTAssertEqual(filled(attributed, Tokens.Color.findCurrentFill), ["Met for men"])
        // Nothing else is styled.
        for run in attributed.runs where run.backgroundColor == nil {
            XCTAssertNil(run.underlineStyle)
            XCTAssertNil(run.foregroundColor)
        }
        // No find: the line is plain.
        XCTAssertEqual(TranscriptLineText.attributed(line, tokens: heard.tokens), AttributedString(line.text))
    }

    func testCorrectionUnderlineAndMatchFillCoexist() throws {
        var item = row()
        _ = try item.applyCorrections(
            TranscriptCorrectionPlan(add: [
                TranscriptCorrection(
                    wordRange: 3..<6, heard: "", text: "metformin", origin: .replace, createdAt: now, updatedAt: now)
            ]), now: now)
        let heard = item.text(.heard)
        let line = try XCTUnwrap(heard.lines.first)
        XCTAssertEqual(line.text, "The patient takes metformin daily. Met for men again.")
        let matches = TranscriptSearchIndex(blocks: [line.text]).matches(for: "met").map(\.range)
        XCTAssertEqual(matches.count, 2)
        let attributed = TranscriptLineText.attributed(
            line, tokens: heard.tokens, find: .init(matches: matches, current: matches[0]))
        let underlinedAndFilled = attributed.runs.compactMap { run -> String? in
            guard run.underlineStyle != nil, run.backgroundColor == Tokens.Color.findCurrentFill else { return nil }
            return String(attributed[run.range].characters)
        }
        XCTAssertEqual(underlinedAndFilled, ["met"], "the match inside the correction keeps its underline")
        let underlined = attributed.runs.filter { $0.underlineStyle != nil }
            .map { String(attributed[$0.range].characters) }
            .joined()
        XCTAssertEqual(underlined, "metformin", "the whole correction is still underlined")
        XCTAssertEqual(filled(attributed, Tokens.Color.findMatchFill), ["Met"])
    }

    func testCounterTextAndNoMatches() {
        let find = TranscriptFindModel()
        find.setBlocks(["The patient takes met for men daily.", "Met for men again."])
        XCTAssertEqual(find.counterText, "")
        find.setQuery("met for men")
        XCTAssertEqual(find.counterText, "1 of 2")
        find.next()
        XCTAssertEqual(find.counterText, "2 of 2")
        find.setQuery("zebra")
        XCTAssertEqual(find.counterText, "No matches")
        XCTAssertEqual(TranscriptFindCopy.playFrom(ms: 724_000), "Play from 12:04")
        XCTAssertEqual(TranscriptFindCopy.counterAccessibility(find.counterText), "No matches")
        XCTAssertEqual(TranscriptFindCopy.counterAccessibility(""), "")
    }

    func testReplaceAllDialogCopy() {
        XCTAssertEqual(TranscriptFindCopy.replaceAllTitle(count: 12), "Replace 12 matches?")
        XCTAssertEqual(TranscriptFindCopy.replaceAllTitle(count: 1), "Replace 1 match?")
        XCTAssertEqual(
            TranscriptFindCopy.replaceAllMessage(query: "met for men", replacement: "metformin", count: 12),
            "“met for men” becomes “metformin” in 12 places. They are corrections you can undo together.")
        XCTAssertEqual(
            TranscriptFindCopy.replaceAllMessage(query: "met for men", replacement: "metformin", count: 1),
            "“met for men” becomes “metformin” in 1 place. They are corrections you can undo together.")
        XCTAssertEqual(TranscriptFindCopy.replaced(count: 12), "Replaced 12.")
        XCTAssertEqual(TranscriptFindCopy.replaced(count: 1), "Replaced.")
        XCTAssertEqual(TranscriptFindCopy.replacedAnnouncement(left: 11), "Replaced. 11 matches left.")
        XCTAssertEqual(TranscriptFindCopy.replacedAnnouncement(left: 1), "Replaced. 1 match left.")
        XCTAssertEqual(TranscriptFindCopy.replacedAnnouncement(left: 0), "Replaced. No matches left.")
        XCTAssertEqual(
            TranscriptFindCopy.skipped(2), "2 places had changed, so they were left as they are.")
        XCTAssertEqual(TranscriptFindCopy.skipped(1), "1 place had changed, so it was left as it is.")
    }

    func testRulePromptClinicalNote() {
        let suggestion = LearnedRuleSuggestion(word: "met for men", replacement: "metformin")
        let personal = TranscriptFindCopy.rulePrompt(suggestion, privacyClass: .personal)
        XCTAssertEqual(personal.question, "Also fix “met for men” in future transcripts?")
        XCTAssertNil(personal.note)
        let general = TranscriptFindCopy.rulePrompt(suggestion, privacyClass: .general)
        XCTAssertNil(general.note)
        let clinical = TranscriptFindCopy.rulePrompt(suggestion, privacyClass: .clinical)
        XCTAssertEqual(clinical.question, personal.question)
        XCTAssertEqual(
            clinical.note, "Saved in Settings → Text rules for all transcripts. Don’t add patient names.")
        XCTAssertEqual(TranscriptFindCopy.ruleAdded, "Rule added. New transcripts get this fix as a correction.")
    }
}
