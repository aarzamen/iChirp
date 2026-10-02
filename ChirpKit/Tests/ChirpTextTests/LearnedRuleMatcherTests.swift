import ChirpCore
import Foundation
import XCTest

@testable import ChirpText

/// Plan 025 Step B3: learned rules ("Also fix future transcripts") become `rule` corrections of the words as heard,
/// matched as custom words are (whole word, case-insensitive). Synthetic content only.
final class LearnedRuleMatcherTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 790_000_000)

    /// Two lines: S1 then S2 (a speaker change breaks the paragraph).
    private func transcription(_ first: String, _ second: String? = nil) -> Transcription {
        var row = Transcription(sourceType: .file, fileName: "Synthetic.m4a", status: .completed)
        var words: [WordTimestamp] = []
        for (speaker, text) in [("S1", first), ("S2", second)] {
            guard let text else { continue }
            for piece in text.split(separator: " ") {
                let start = words.count * 300
                words.append(
                    WordTimestamp(
                        word: String(piece), startMs: start, endMs: start + 250, confidence: 0.9, speakerId: speaker))
            }
        }
        row.wordTimestamps = words
        row.rawTranscript = [first, second].compactMap { $0 }.joined(separator: " ")
        return row
    }

    private func rule(_ word: String, _ replacement: String) -> CustomWord {
        CustomWord(word: word, replacement: replacement, source: .learned)
    }

    private func apply(_ plan: TranscriptCorrectionPlan, to row: Transcription) throws -> Transcription {
        var row = row
        _ = try row.applyCorrections(plan, now: now)
        return row
    }

    func testWholeWordCaseInsensitive() throws {
        let row = transcription("Smyth saw Dr. SMYTH and smythe.", "Ask smyth again")
        let learned = rule("smyth", "Smith")
        let plan = LearnedRuleMatcher.plan(row.text(.heard), rules: [learned], now: now)
        XCTAssertEqual(plan.add.count, 3, "smythe is another word")
        XCTAssertTrue(plan.add.allSatisfy { $0.origin == .rule && $0.ruleID == learned.id })
        XCTAssertEqual(Set(plan.add.compactMap(\.batchID)).count, 1, "one rule, one batch")
        let corrected = try apply(plan, to: row)
        XCTAssertEqual(
            corrected.plainText(.shown(.raw)), "Smith saw Dr. Smith and smythe. Ask Smith again")
        XCTAssertEqual(corrected.textCorrections?.items.map(\.heard), ["Smyth", "SMYTH", "smyth"])
    }

    func testMultiWordPhrase() throws {
        let row = transcription("She takes met for men daily", "Continue Met For Men, then stop")
        let plan = LearnedRuleMatcher.plan(row.text(.heard), rules: [rule("met for men", "metformin")], now: now)
        let corrected = try apply(plan, to: row)
        XCTAssertEqual(
            corrected.plainText(.shown(.raw)), "She takes metformin daily Continue metformin, then stop")
        XCTAssertEqual(corrected.textCorrections?.items.map(\.wordRange.startIndex), [2, 7])
        XCTAssertEqual(corrected.textCorrections?.items.map(\.heard), ["met for men", "Met For Men,"])
        XCTAssertEqual(corrected.textCorrections?.items.map(\.text), ["metformin", "metformin,"])
    }

    func testNoMatchMakesNoPlan() {
        let row = transcription("She takes metformin daily")
        XCTAssertTrue(
            LearnedRuleMatcher.plan(row.text(.heard), rules: [rule("met for men", "metformin")], now: now).isEmpty)
        XCTAssertTrue(LearnedRuleMatcher.plan(row.text(.heard), rules: [], now: now).isEmpty)
        // A rule without a replacement, or turned off, changes nothing.
        var off = rule("metformin", "Metformin")
        off.isEnabled = false
        XCTAssertTrue(LearnedRuleMatcher.plan(row.text(.heard), rules: [off], now: now).isEmpty)
        XCTAssertTrue(
            LearnedRuleMatcher.plan(
                row.text(.heard), rules: [CustomWord(word: "metformin", source: .learned)], now: now
            ).isEmpty)
        // Untimed rows have no tokens to correct.
        var untimed = row
        untimed.wordTimestamps = nil
        XCTAssertTrue(
            LearnedRuleMatcher.plan(untimed.text(.heard), rules: [rule("metformin", "Glucophage")], now: now).isEmpty)
    }

    func testCorrectedWordsAreLeftAlone() throws {
        var row = transcription("She takes met for men daily and met for men nightly")
        // The person already corrected the first place to something else.
        row = try apply(
            TranscriptCorrectionPlan(add: [
                TranscriptCorrection(
                    wordRange: 2..<5, heard: "", text: "Metformin XR", origin: .edit, createdAt: now, updatedAt: now)
            ]), to: row)
        let plan = LearnedRuleMatcher.plan(row.text(.heard), rules: [rule("met for men", "metformin")], now: now)
        XCTAssertEqual(plan.remove, [])
        XCTAssertEqual(plan.add.map(\.wordRange.startIndex), [7])
    }

    func testOverlappingRulesTakeTheFirst() {
        let row = transcription("She takes met for men daily")
        let plan = LearnedRuleMatcher.plan(
            row.text(.heard), rules: [rule("met for men", "metformin"), rule("for men", "formen")], now: now)
        XCTAssertEqual(plan.add.map(\.text), ["metformin"])
    }

    func testWholeWordCheckMatchesTheRuleSemantics() {
        let text = "met for men, metformin, smet"
        XCTAssertTrue(LearnedRuleMatcher.isWholeWord(NSRange(location: 0, length: 11), in: text, word: "met for men"))
        XCTAssertTrue(LearnedRuleMatcher.isWholeWord(NSRange(location: 0, length: 3), in: text, word: "met"))
        XCTAssertFalse(LearnedRuleMatcher.isWholeWord(NSRange(location: 13, length: 3), in: text, word: "met"))
        XCTAssertFalse(LearnedRuleMatcher.isWholeWord(NSRange(location: 25, length: 3), in: text, word: "met"))
        // Diacritics count for a rule (find ignores them; a rule would not find the place).
        XCTAssertFalse(LearnedRuleMatcher.isWholeWord(NSRange(location: 0, length: 4), in: "café", word: "cafe"))
    }
}
