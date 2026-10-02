import ChirpCore
import XCTest

@testable import ChirpText

/// Review R5-2 (plan 025 ruling 2, R5-a): a dictation's applied voice commands become `voiceCommand` corrections of
/// its words, so the stored transcript, and every view of it, reads what the person meant. Synthetic content only.
final class VoiceCommandCorrectionsTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 790_000_000)
    private let batch = UUID()

    private func words(_ text: String) -> [WordTimestamp] {
        text.split(separator: " ").enumerated().map { index, word in
            WordTimestamp(word: String(word), startMs: index * 300, endMs: index * 300 + 250, confidence: 0.9)
        }
    }

    private func dictation(_ heard: String, clean: String? = nil) -> Transcription {
        var row = Transcription(sourceType: .dictation, fileName: "Dictation.wav", status: .completed)
        row.wordTimestamps = words(heard)
        row.rawTranscript = heard
        row.cleanTranscript = clean
        return row
    }

    /// The row with the plan for `commanded` → `result` applied.
    private func applying(_ row: Transcription, commanded: String, result: String) throws -> Transcription {
        let plan = try XCTUnwrap(
            VoiceCommandCorrections.plan(
                words: row.wordTimestamps ?? [], commandedText: commanded, resultText: result, batchID: batch, now: now))
        XCTAssertTrue(plan.add.allSatisfy { $0.origin == .voiceCommand && $0.batchID == batch })
        var row = row
        _ = try row.applyCorrections(plan, now: now)
        return row
    }

    func testScratchThatRemovesTheScratchedSentenceFromTheStream() throws {
        let heard = "Patient seen today. Take aspirin 81 mg. Scratch that. Recheck in two weeks. Send to SOAP."
        let result = "Patient seen today. Recheck in two weeks."
        let item = try applying(dictation(heard), commanded: heard, result: result)
        XCTAssertEqual(item.plainText(.shown(.raw)), result)
        XCTAssertEqual(item.text(.shown(.raw)).plainText, result)
        let modelInput = TranscriptPromptFormatter.modelInput(item.text(.shown(.raw)))
        XCTAssertFalse(modelInput.contains("aspirin"), modelInput)
        XCTAssertFalse(modelInput.localizedCaseInsensitiveContains("scratch"), modelInput)
        XCTAssertFalse(modelInput.localizedCaseInsensitiveContains("soap"), modelInput)
        XCTAssertEqual(item.rawTranscript, heard, "the words as heard are kept")
        XCTAssertEqual(item.textCorrections?.items.map(\.heard).joined(separator: " ").contains("aspirin"), true)
    }

    func testNewParagraphKeepsTheBreakInsideACorrection() throws {
        let heard = "Patient seen today. New paragraph. Plan is rest."
        let result = "Patient seen today.\n\nPlan is rest."
        let item = try applying(dictation(heard), commanded: heard, result: result)
        XCTAssertEqual(item.plainText(.shown(.raw)), result)
        XCTAssertEqual(item.textCorrections?.items.map(\.text), ["today.\n\nPlan"])
    }

    func testCommandsOnCleanTextAlignToTheHeardWords() throws {
        // The commands ran on the clean text (filler gone, custom word applied); the corrections still land on the
        // engine's words, and the dictation's shown text is the clean-up of the corrected words.
        let heard = "Um, patient on zarelto daily. Take aspirin 81 mg. Delete that. Recheck in two weeks."
        let clean = "Patient on Xarelto daily. Take aspirin 81 mg. Delete that. Recheck in two weeks."
        let result = "Patient on Xarelto daily. Recheck in two weeks."
        let item = try applying(dictation(heard, clean: clean), commanded: clean, result: result)
        let context = TranscriptTextContext(customWords: [CustomWord(word: "zarelto", replacement: "Xarelto")])
        XCTAssertEqual(item.plainText(.shown(.raw), context: context), result)
        XCTAssertEqual(item.plainText(.shown(.clean), context: context), result)
        XCTAssertFalse(item.plainText(.heard).contains("aspirin"))
        // Words outside the edited stretch stay as heard; a clean word next to it (Xarelto) joins the correction.
        XCTAssertTrue(item.plainText(.heard).hasPrefix("Um, patient on"), item.plainText(.heard))
        XCTAssertTrue(item.plainText(.heard).hasSuffix("Recheck in two weeks."), item.plainText(.heard))
    }

    func testUnchangedTextMakesNoPlan() {
        let heard = "Patient seen today."
        XCTAssertEqual(
            VoiceCommandCorrections.plan(
                words: words(heard), commandedText: heard, resultText: heard + " ", batchID: batch, now: now
            )?.isEmpty, true)
    }

    func testTextThatDoesNotMatchTheWordsBecomesOneCorrectionOverEveryWord() throws {
        let item = try applying(
            dictation("Hello there. General Kenobi."), commanded: "Something else entirely. Scratch that. Fine.",
            result: "Fine.")
        XCTAssertEqual(item.textCorrections?.items.map(\.range), [0..<4])
        XCTAssertEqual(item.plainText(.shown(.raw)), "Fine.")
    }

    func testAnEmptyResultCannotBeStored() {
        let heard = "Take aspirin. Scratch that."
        XCTAssertNil(
            VoiceCommandCorrections.plan(
                words: words(heard), commandedText: heard, resultText: "  ", batchID: batch, now: now))
    }
}
