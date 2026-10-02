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

    // MARK: - Fix round 1

    /// I4: the current match has a cue that is not a colour: bold and a solid underline (other matches neither).
    func testCurrentMatchIsBoldAndUnderlined() throws {
        let heard = row().text(.heard)
        let line = try XCTUnwrap(heard.lines.first)
        let attributed = TranscriptLineText.attributed(
            line, tokens: heard.tokens, find: marks(line, query: "met for men", current: 1))
        let cued = attributed.runs.compactMap { run -> String? in
            guard run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true,
                run.underlineStyle == Text.LineStyle(pattern: .solid, color: Tokens.Color.ink)
            else { return nil }
            return String(attributed[run.range].characters)
        }
        XCTAssertEqual(cued, ["Met for men"])
        for run in attributed.runs where run.backgroundColor == Tokens.Color.findMatchFill {
            XCTAssertNil(run.inlinePresentationIntent)
            XCTAssertNil(run.underlineStyle)
        }
    }

    /// I2, M2, C1: the result line says what happened, counts only.
    func testResultLineSaysWhatWasLeftAndWhyThereIsNoRule() {
        let plan = TranscriptCorrectionPlan(remove: [UUID()])
        let outcome = ReplaceOutcome(
            undo: plan, count: 3, skipped: 2, skippedInCorrections: 2,
            ruleWithheld: LearnedRuleSuggestion.numbersReason)
        let result = ReplaceResult.make(outcome, privacyClass: .clinical)
        XCTAssertEqual(result.message, "Replaced 3. 2 in a corrected passage were left as they are.")
        XCTAssertTrue(result.canUndo)
        XCTAssertNil(result.suggestion)
        XCTAssertEqual(result.withheld, "Rules can’t contain numbers or dose units, so a dose is never changed automatically.")
        XCTAssertEqual(
            ReplaceResult.make(ReplaceOutcome(undo: plan, count: 1, skipped: 1), privacyClass: .personal).message,
            "Replaced. 1 place had changed, so it was left as it is.")
        let nothing = ReplaceResult.make(ReplaceOutcome(undo: .init(), count: 0), privacyClass: .personal)
        XCTAssertEqual(nothing.message, "Nothing changed.")
        XCTAssertFalse(nothing.canUndo)
        XCTAssertNil(nothing.withheld)
        let offered = ReplaceResult.make(
            ReplaceOutcome(
                undo: plan, count: 1, ruleSuggestion: LearnedRuleSuggestion(word: "met for men", replacement: "x")),
            privacyClass: .clinical)
        XCTAssertEqual(offered.note, LearnedRuleSuggestion.clinicalNote)
    }

    /// I3, M3: announcements carry counts and what can be done, never transcript text or rule words.
    func testAnnouncementsCarryNoContent() {
        let plan = TranscriptCorrectionPlan(remove: [UUID()])
        let offered = ReplaceResult.make(
            ReplaceOutcome(
                undo: plan, count: 2, ruleSuggestion: LearnedRuleSuggestion(word: "met for men", replacement: "x")),
            privacyClass: .personal)
        XCTAssertEqual(
            offered.announcement(matchesLeft: 3), "Replaced. 3 matches left. Undo available. Rule offer available.")
        let plain = ReplaceResult.make(ReplaceOutcome(undo: plan, count: 1), privacyClass: .personal)
        XCTAssertEqual(plain.announcement(matchesLeft: 0), "Replaced. No matches left. Undo available.")
        let nothing = ReplaceResult.make(ReplaceOutcome(undo: .init(), count: 0), privacyClass: .personal)
        XCTAssertEqual(nothing.announcement(matchesLeft: 1), "Nothing changed.")
        XCTAssertEqual(
            TranscriptFindCopy.ruleStatusAnnouncement(.alreadyExists("“met for men” already has a rule")),
            "That rule already exists.")
        XCTAssertEqual(TranscriptFindCopy.ruleStatusAnnouncement(.added), TranscriptFindCopy.ruleAdded)
        XCTAssertEqual(
            TranscriptFindCopy.ruleStatusAnnouncement(.refused(LearnedRuleSuggestion.numbersReason)),
            LearnedRuleSuggestion.numbersReason)
        XCTAssertEqual(TranscriptFindCopy.ruleStatusAnnouncement(.failed("disk full")), "The rule wasn’t saved.")
    }

    /// M4: a learned rule cannot be saved without its replacement (a manual word can).
    func testLearnedRuleNeedsAReplacementToSave() {
        let learned = CustomWord(word: "met for men", replacement: "metformin", source: .learned)
        let manual = CustomWord(word: "Kenobi")
        XCTAssertFalse(TextRuleEditorSheet.canSave(.word(learned), first: "met for men", second: "  "))
        XCTAssertTrue(TextRuleEditorSheet.canSave(.word(learned), first: "met for men", second: "metformin"))
        XCTAssertTrue(TextRuleEditorSheet.canSave(.word(manual), first: "Kenobi", second: ""))
        XCTAssertFalse(TextRuleEditorSheet.canSave(.newSnippet, first: "my sig", second: ""))
    }

    // MARK: - Fix round 2

    /// N1: a replace that changed nothing says why when matches were left alone.
    func testNothingChangedSaysWhy() {
        let inCorrections = ReplaceResult.make(
            ReplaceOutcome(undo: .init(), count: 0, skipped: 2, skippedInCorrections: 2), privacyClass: .personal)
        XCTAssertEqual(inCorrections.message, "Nothing changed. 2 in a corrected passage were left as they are.")
        let stale = ReplaceResult.make(ReplaceOutcome(undo: .init(), count: 0, skipped: 1), privacyClass: .personal)
        XCTAssertEqual(stale.message, "Nothing changed. 1 place had changed, so it was left as it is.")
    }

    /// N4: a withheld offer is announced as "No rule offer." (no content).
    func testWithheldOfferIsAnnounced() {
        let result = ReplaceResult.make(
            ReplaceOutcome(
                undo: TranscriptCorrectionPlan(remove: [UUID()]), count: 1,
                ruleWithheld: LearnedRuleSuggestion.numbersReason),
            privacyClass: .personal)
        XCTAssertEqual(result.announcement(matchesLeft: 0), "Replaced. No matches left. Undo available. No rule offer.")
    }
}
