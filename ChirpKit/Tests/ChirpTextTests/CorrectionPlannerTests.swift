import ChirpCore
import XCTest

@testable import ChirpText

/// Plan 025 Step A4: an edited line becomes the smallest word-span corrections. Synthetic content only.
final class CorrectionPlannerTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 790_000_000)

    private func row(_ text: String) -> Transcription {
        var row = Transcription(fileName: "synthetic.m4a", status: .completed)
        let words = text.split(separator: " ").enumerated().map { index, word in
            WordTimestamp(word: String(word), startMs: index * 300, endMs: index * 300 + 250, confidence: 0.9)
        }
        row.wordTimestamps = words
        row.rawTranscript = text
        return row
    }

    private func plan(_ row: Transcription, line: Int = 0, _ edited: String, batchID: UUID? = nil) throws
        -> TranscriptCorrectionPlan
    {
        let text = row.text(.heard)
        return try CorrectionPlanner.plan(
            line: text.lines[line], tokens: text.tokens, heard: { row.heardText($0) }, editedText: edited,
            origin: .edit, batchID: batchID, now: now)
    }

    /// The plan applied: the ranges and texts of the row's corrections afterwards.
    private func applied(_ row: Transcription, _ plan: TranscriptCorrectionPlan) throws -> Transcription {
        var row = row
        row.textCorrections = try (row.textCorrections ?? .empty).applying(
            plan, words: row.wordTimestamps ?? [], now: now
        ).corrections
        return row
    }

    private func spans(_ plan: TranscriptCorrectionPlan) -> [String] {
        plan.add.map { "\($0.range.lowerBound)..<\($0.range.upperBound) \($0.text)" }
    }

    private let sentence = "the patient takes met for men daily."

    func testReplaceOneWord() throws {
        let result = try plan(row(sentence), "the person takes met for men daily.")
        XCTAssertEqual(spans(result), ["1..<2 person"])
        XCTAssertEqual(result.remove, [])
        XCTAssertEqual(result.add.first?.origin, .edit)
        XCTAssertEqual(result.add.first?.createdAt, now)
    }

    func testReplaceThreeWordsWithOne() throws {
        let item = row(sentence)
        let result = try plan(item, "the patient takes metformin daily.")
        XCTAssertEqual(spans(result), ["3..<6 metformin"])
        let corrected = try applied(item, result)
        XCTAssertEqual(corrected.text(.heard).lines[0].text, "the patient takes metformin daily.")
        XCTAssertEqual(corrected.textCorrections?.items.first?.heard, "met for men")
    }

    func testInsertionAttachesToThePreviousWord() throws {
        let result = try plan(row(sentence), "the patient takes met for men twice daily.")
        XCTAssertEqual(spans(result), ["5..<6 men twice"])
    }

    func testInsertionAtLineStartAttachesToTheNextWord() throws {
        let result = try plan(row(sentence), "Today the patient takes met for men daily.")
        XCTAssertEqual(spans(result), ["0..<1 Today the"])
    }

    func testDeletionAttachesToANeighbor() throws {
        XCTAssertEqual(spans(try plan(row(sentence), "the patient takes met for men.")), ["5..<7 men."])
        XCTAssertEqual(spans(try plan(row(sentence), "patient takes met for men daily.")), ["0..<2 patient"])
    }

    func testTwoSeparateChangesMakeTwoCorrections() throws {
        let batch = UUID()
        let result = try plan(row(sentence), "The patient takes metformin daily.", batchID: batch)
        XCTAssertEqual(spans(result), ["0..<1 The", "3..<6 metformin"])
        XCTAssertEqual(Set(result.add.map(\.batchID)), [batch])
    }

    func testAdjacentChangesMerge() throws {
        // "takes" and "met for men" change next to each other: one correction.
        let result = try plan(row(sentence), "the patient took metformin daily.")
        XCTAssertEqual(spans(result), ["2..<6 took metformin"])
    }

    func testEditingInsideACorrectionUpdatesIt() throws {
        let item = try applied(row(sentence), try plan(row(sentence), "the patient takes metformin daily."))
        let firstID = try XCTUnwrap(item.textCorrections?.items.first?.id)
        let result = try plan(item, "the patient takes metformin XR daily.")
        XCTAssertEqual(spans(result), ["3..<6 metformin XR"])
        XCTAssertEqual(result.remove, [firstID])
        let updated = try applied(item, result)
        XCTAssertEqual(updated.textCorrections?.items.map(\.text), ["metformin XR"])
        XCTAssertEqual(updated.text(.heard).lines[0].text, "the patient takes metformin XR daily.")
    }

    func testRetypingTheHeardWordsRevertsThem() throws {
        let item = try applied(row(sentence), try plan(row(sentence), "the patient takes metformin daily."))
        let result = try plan(item, sentence)
        XCTAssertEqual(result.add, [])
        XCTAssertEqual(result.remove, Set(item.textCorrections?.items.map(\.id) ?? []))
        XCTAssertEqual(try applied(item, result).textCorrections?.items, [])
    }

    func testPunctuationAndCaseChangesCount() throws {
        XCTAssertEqual(spans(try plan(row(sentence), "The patient takes met for men daily!")), ["0..<1 The", "6..<7 daily!"])
    }

    func testWhitespaceOnlyChangeIsNoChange() throws {
        let result = try plan(row(sentence), "  the patient\ntakes   met for men\tdaily.  ")
        XCTAssertTrue(result.isEmpty)
    }

    func testBlankTextThrows() throws {
        XCTAssertThrowsError(try plan(row(sentence), " \n ")) { error in
            XCTAssertEqual(error as? TranscriptCorrectionsError, .emptyText)
        }
    }

    func testUnicodeWords() throws {
        let item = row("café naïve 🙂 我爱你 end.")
        XCTAssertEqual(spans(try plan(item, "café naive 🙂 我恨你 end.")), ["1..<2 naive", "3..<4 我恨你"])
        XCTAssertEqual(spans(try plan(item, "café naïve 👍🏽 我爱你 end.")), ["2..<3 👍🏽"])
    }

    func testTheSecondLineIsPlannedOnItsOwnWords() throws {
        // Two lines (a 2.5 s pause between them): the planner works inside the line it is given.
        var item = row("first line here. second line here.")
        item.wordTimestamps = item.wordTimestamps?.enumerated().map { index, word in
            var copy = word
            if index >= 3 {
                copy.startMs += 5_000
                copy.endMs += 5_000
            }
            return copy
        }
        XCTAssertEqual(item.text(.heard).lines.count, 2)
        XCTAssertEqual(spans(try plan(item, line: 1, "second lane here.")), ["4..<5 lane"])
    }
}
