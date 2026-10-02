import ChirpCore
import ChirpText
import Foundation
import XCTest

@testable import ChirpFeatures

/// Plan 025 Steps B2–B3: the Transcript screen's find timing, Replace and Replace All (corrections through the one
/// writer, never the words as heard) and the "Also fix future transcripts" offer. Synthetic content only.
@MainActor
final class TranscriptViewModelReplaceTests: XCTestCase {
    static let first = "The patient takes met for men daily."
    static let second = "Continue met for men and recheck."

    /// Line 0 (S1) and line 1 (S2); words 300 ms apart.
    static func row(clean: String? = nil) -> Transcription {
        var row = Transcription(sourceType: .file, fileName: "Synthetic visit.m4a", status: .completed)
        var words: [WordTimestamp] = []
        for (speaker, text) in [("S1", first), ("S2", second)] {
            for piece in text.split(separator: " ") {
                let start = words.count * 300
                words.append(
                    WordTimestamp(
                        word: String(piece), startMs: start, endMs: start + 250, confidence: 0.9, speakerId: speaker))
            }
        }
        row.wordTimestamps = words
        row.transcriptSegments = FileTranscriptSegments.materialize(words: words)
        row.rawTranscript = first + " " + second
        row.cleanTranscript = clean
        return row
    }

    private func viewModel(_ store: FakeStore, _ row: Transcription) -> TranscriptViewModel {
        TranscriptViewModel(
            id: row.id, store: store, paths: AppPaths(root: FileManager.default.temporaryDirectory),
            settings: InMemorySettingsStore(),
            corrections: TranscriptCorrectionService(store: store, context: { .none }))
    }

    private func loaded(_ row: Transcription = row()) async -> (TranscriptViewModel, FakeStore) {
        let store = FakeStore(rows: [row])
        let model = viewModel(store, row)
        await model.load()
        return (model, store)
    }

    private func find(_ query: String, in model: TranscriptViewModel) -> [TranscriptFindMatch] {
        TranscriptSearchIndex(blocks: model.findBlocks).matches(for: query)
    }

    // MARK: - Timing

    func testTimeOfAMatchIsTheStartOfItsToken() async throws {
        let (model, _) = await loaded()
        let matches = find("for men", in: model)
        XCTAssertEqual(matches.count, 2)
        XCTAssertEqual(model.timeMs(of: matches[0]), 4 * 300, "\"for\" is word 4")
        XCTAssertEqual(model.timeMs(of: matches[1]), 9 * 300, "the second line's \"for\" is word 9")
        // A match inside a correction starts at the correction's envelope.
        _ = try await model.replace(matches[1], query: "for men", with: "formen")
        let corrected = find("formen", in: model)
        XCTAssertEqual(corrected.count, 1)
        XCTAssertEqual(model.timeMs(of: corrected[0]), 9 * 300)
        // Untimed rows have no times.
        var untimed = Self.row()
        untimed.wordTimestamps = nil
        let (plain, _) = await loaded(untimed)
        XCTAssertNil(plain.timeMs(of: find("met", in: plain)[0]))
    }

    // MARK: - Replace

    func testReplaceMakesOneCorrection() async throws {
        let (model, store) = await loaded()
        let match = find("met for men", in: model)[1]
        let outcome = try await model.replace(match, query: "met for men", with: "metformin")
        XCTAssertEqual(outcome.count, 1)
        XCTAssertEqual(outcome.skipped, 0)
        XCTAssertEqual(model.corrections.map(\.text), ["metformin"])
        XCTAssertEqual(model.corrections.map(\.origin), [.replace])
        XCTAssertEqual(model.corrections.map(\.heard), ["met for men"])
        XCTAssertEqual(model.lines.map(\.text), [Self.first, "Continue metformin and recheck."])
        let stored = await store.row(model.id)
        XCTAssertEqual(stored?.rawTranscript, Self.first + " " + Self.second, "the words as heard are never rewritten")
        // Undo puts the heard words back.
        try await model.undo(outcome.undo)
        XCTAssertEqual(model.corrections, [])
    }

    func testReplaceAllMakesOneBatchAndUndoRevertsIt() async throws {
        let (model, store) = await loaded()
        let matches = find("met for men", in: model)
        let writesBefore = await store.textCorrectionWrites
        let outcome = try await model.replaceAll(matches, query: "met for men", with: "metformin")
        let writesAfter = await store.textCorrectionWrites
        XCTAssertEqual(writesAfter - writesBefore, 1, "one plan, one write")
        XCTAssertEqual(outcome.count, 2)
        XCTAssertEqual(model.corrections.map(\.origin), [.replaceAll, .replaceAll])
        XCTAssertEqual(Set(model.corrections.compactMap(\.batchID)).count, 1)
        XCTAssertEqual(
            model.lines.map(\.text),
            ["The patient takes metformin daily.", "Continue metformin and recheck."])
        try await model.undo(outcome.undo)
        XCTAssertEqual(model.corrections, [])
        XCTAssertEqual(model.lines.map(\.text), [Self.first, Self.second])
    }

    func testReplaceAllSeveralMatchesInOneLine() async throws {
        let (model, _) = await loaded()
        let matches = find("e", in: model).filter { $0.blockIndex == 0 }
        XCTAssertGreaterThan(matches.count, 2)
        let outcome = try await model.replaceAll(matches, query: "e", with: "E")
        XCTAssertEqual(outcome.count, matches.count)
        XCTAssertEqual(model.lines.first?.text, "ThE patiEnt takEs mEt for mEn daily.")
        XCTAssertEqual(model.lines.last?.text, Self.second)
    }

    func testReplaceInsideAWordKeepsTheRestOfTheWord() async throws {
        let (model, _) = await loaded()
        let match = try XCTUnwrap(find("tak", in: model).first)
        try await model.replace(match, query: "tak", with: "mak")
        XCTAssertEqual(model.lines.first?.text, "The patient makes met for men daily.")
        XCTAssertEqual(model.corrections.map(\.heard), ["takes"])
        XCTAssertEqual(model.corrections.map(\.text), ["makes"])
    }

    func testReplaceSkipsAMatchThatNoLongerMatches() async throws {
        let (model, _) = await loaded()
        let stale = find("met for men", in: model)
        try await model.replace(stale[0], query: "met for men", with: "metformin")
        // The first match's place now reads "metformin"; the old list still names it.
        let outcome = try await model.replaceAll(stale, query: "met for men", with: "metformin")
        XCTAssertEqual(outcome.count, 1)
        XCTAssertEqual(outcome.skipped, 1)
        XCTAssertEqual(model.corrections.count, 2)
    }

    func testReplaceNeedsACorrectionWriterAndTimings() async throws {
        let row = Self.row()
        let store = FakeStore(rows: [row])
        let readOnly = TranscriptViewModel(
            id: row.id, store: store, paths: AppPaths(root: FileManager.default.temporaryDirectory),
            settings: InMemorySettingsStore())
        await readOnly.load()
        XCTAssertFalse(readOnly.canReplace)
        let (model, _) = await loaded()
        XCTAssertTrue(model.canReplace)
        var untimed = Self.row()
        untimed.wordTimestamps = nil
        let (plain, _) = await loaded(untimed)
        XCTAssertFalse(plain.canReplace)
        XCTAssertEqual(plain.replaceUnavailableReason, "Replace needs word timings; this transcript has none.")
    }

    // MARK: - Also fix future transcripts (D8)

    func testRuleSuggestionOnlyForWholeWordMatches() async throws {
        let (model, _) = await loaded()
        let whole = try await model.replaceAll(
            find("met for men", in: model), query: "met for men", with: "metformin")
        XCTAssertEqual(whole.ruleSuggestion, LearnedRuleSuggestion(word: "met for men", replacement: "metformin"))
        try await model.revertAll()

        // Inside a word: a rule (whole words) would not find the same places.
        let partial = try await model.replaceAll(find("tak", in: model), query: "tak", with: "mak")
        XCTAssertNil(partial.ruleSuggestion)
        try await model.revertAll()
        // Too short, or no letter.
        let short = try await model.replaceAll(find("met", in: model), query: "me", with: "Me")
        XCTAssertNil(short.ruleSuggestion)
        try await model.revertAll()
        // Edge spaces: the rule would be the trimmed word, which can find other places.
        let spaced = try await model.replaceAll(find("met ", in: model), query: "met ", with: "Met ")
        XCTAssertNil(spaced.ruleSuggestion)
        try await model.revertAll()
        // A blank or identical replacement is no rule.
        let same = LearnedRuleSuggestion.make(
            query: "patient", replacement: "patient", replaced: [(Self.first, NSRange(location: 4, length: 7))])
        XCTAssertNil(same)
        let blank = LearnedRuleSuggestion.make(
            query: "patient", replacement: "  ", replaced: [(Self.first, NSRange(location: 4, length: 7))])
        XCTAssertNil(blank)
        let one = LearnedRuleSuggestion.make(
            query: "patient", replacement: "client", replaced: [(Self.first, NSRange(location: 4, length: 7))])
        XCTAssertEqual(one, LearnedRuleSuggestion(word: "patient", replacement: "client"))
    }

    // MARK: - Fix round 1

    /// I2: a match inside a passage corrected earlier (another batch) is skipped and counted, so reverting this Replace
    /// all never takes the person's correction with it.
    func testReplaceAllSkipsMatchesInsideAnotherCorrection() async throws {
        var row = Transcription(sourceType: .file, fileName: "Synthetic visit.m4a", status: .completed)
        let text = "Take met for men twice daily. Walk twice a week."
        row.wordTimestamps = text.split(separator: " ").enumerated().map { index, word in
            WordTimestamp(word: String(word), startMs: index * 300, endMs: index * 300 + 250, confidence: 0.9)
        }
        row.rawTranscript = text
        let now = Date(timeIntervalSinceReferenceDate: 790_000_000)
        _ = try row.applyCorrections(
            TranscriptCorrectionPlan(add: [
                TranscriptCorrection(
                    wordRange: 1..<5, heard: "", text: "metformin twice", origin: .edit, createdAt: now,
                    updatedAt: now)
            ]), now: now)
        let (model, _) = await loaded(row)
        XCTAssertEqual(model.lines.first?.text, "Take metformin twice daily. Walk twice a week.")
        let outcome = try await model.replaceAll(find("twice", in: model), query: "twice", with: "two times")
        XCTAssertEqual(outcome.count, 1)
        XCTAssertEqual(outcome.skipped, 1)
        XCTAssertEqual(outcome.skippedInCorrections, 1)
        XCTAssertEqual(model.lines.first?.text, "Take metformin twice daily. Walk two times a week.")
        // Reverting the Replace all batch (the Corrections sheet's row) leaves the person's correction.
        let batch = Set(model.corrections.filter { $0.origin == .replaceAll }.map(\.id))
        try await model.revert(batch)
        XCTAssertEqual(model.lines.first?.text, "Take metformin twice daily. Walk twice a week.")
    }

    /// M2: a replace that changes nothing says so: no count, no undo, no rule offer.
    func testNoOpReplaceSaysNothingChanged() async throws {
        let (model, store) = await loaded()
        let writes = await store.textCorrectionWrites
        let outcome = try await model.replaceAll(
            find("patient", in: model), query: "patient", with: "patient")
        XCTAssertEqual(outcome.count, 0)
        XCTAssertTrue(outcome.undo.isEmpty)
        XCTAssertNil(outcome.ruleSuggestion)
        let after = await store.textCorrectionWrites
        XCTAssertEqual(after, writes)
        // A lowercase query whose match already reads as the replacement ("the" finds "The"): nothing changes.
        let (other, _) = await loaded()
        let same = try await other.replace(find("the", in: other)[0], query: "the", with: "The")
        XCTAssertEqual(same.count, 0)
        XCTAssertTrue(same.undo.isEmpty)
    }

    /// M6: an untrimmed query keeps its edge spacing, so words never merge.
    func testUntrimmedQueryKeepsItsSpacing() async throws {
        let (model, _) = await loaded()
        let matches = find(" for ", in: model)
        XCTAssertEqual(matches.count, 2)
        try await model.replaceAll(matches, query: " for ", with: "4")
        XCTAssertEqual(model.lines.map(\.text), ["The patient takes met 4 men daily.", "Continue met 4 men and recheck."])
    }

    /// C1: a replacement or a query with a number is never offered as a rule, and the outcome says why.
    func testRuleOfferWithheldForNumbers() async throws {
        let (model, _) = await loaded()
        let outcome = try await model.replaceAll(
            find("met for men", in: model), query: "met for men", with: "metformin 500")
        XCTAssertNil(outcome.ruleSuggestion)
        XCTAssertEqual(outcome.ruleWithheld, LearnedRuleSuggestion.numbersReason)
        XCTAssertEqual(
            LearnedRuleSuggestion.numbersReason, "Rules can’t contain numbers or dose units, so a dose is never changed automatically.")
        XCTAssertNil(
            LearnedRuleSuggestion.make(
                query: "takes", replacement: "takes 2", replaced: [(Self.first, NSRange(location: 12, length: 5))]))
        XCTAssertNil(
            LearnedRuleSuggestion.make(
                query: "0.5 mg", replacement: "5 mg", replaced: [("Give 0.5 mg now", NSRange(location: 5, length: 6))]))
        // No number: the offer stands and nothing is withheld.
        try await model.revertAll()
        let plain = try await model.replaceAll(
            find("met for men", in: model), query: "met for men", with: "metformin")
        XCTAssertNotNil(plain.ruleSuggestion)
        XCTAssertNil(plain.ruleWithheld)
    }

    /// U1: a dose unit on either side withholds the offer, with the one reason line.
    func testRuleOfferWithheldForDoseUnits() {
        let reason = "Rules can’t contain numbers or dose units, so a dose is never changed automatically."
        let text = "Give the mg dose bid"
        for (query, replacement, range) in [
            ("mg", "mcg", NSRange(location: 9, length: 2)), ("bid", "tid", NSRange(location: 17, length: 3)),
        ] {
            XCTAssertNil(LearnedRuleSuggestion.make(query: query, replacement: replacement, replaced: [(text, range)]))
            XCTAssertEqual(LearnedRuleSuggestion.withheldReason(query: query, replacement: replacement), reason)
        }
        XCTAssertNil(LearnedRuleSuggestion.withheldReason(query: "metoprolol", replacement: "metformin"))
    }
}
