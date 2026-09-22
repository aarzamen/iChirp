// Ported from MacParakeet (GPL-3.0): Tests/MacParakeetTests/Services/MeetingRecording/MeetingTranscriptAssemblerTests.swift @ bbae9e0e
// Changes: one source, so no speaker ids or roster; words keep absolute recording times (upstream normalizes the
// first word to 0). Test names kept; the multi-source finalized-transcript test is not ported. Plus paragraphs.

import ChirpCore
import XCTest

@testable import ChirpFeatures

final class MeetingTranscriptAssemblerTests: XCTestCase {
    private func result(_ text: String, _ words: [WordTimestamp] = []) -> SpeechResult {
        SpeechResult(text: text, words: words, language: "en", engineID: "fake", engineVariant: nil)
    }

    private func chunk(_ startMs: Int, _ endMs: Int) -> MeetingAudioChunk {
        MeetingAudioChunk(samples: [0], startMs: startMs, endMs: endMs)
    }

    func testApplyDeduplicatesOverlapForSingleSource() {
        var assembler = MeetingTranscriptAssembler()
        assembler.apply(
            result(
                "Hello team",
                [
                    WordTimestamp(word: "Hello", startMs: 100, endMs: 400, confidence: 0.9),
                    WordTimestamp(word: "team", startMs: 4_200, endMs: 4_600, confidence: 0.9),
                ]), chunk: chunk(0, 5_000))
        assembler.apply(
            result(
                "team again",
                [
                    WordTimestamp(word: "team", startMs: 100, endMs: 500, confidence: 0.9),
                    WordTimestamp(word: "again", startMs: 700, endMs: 1_000, confidence: 0.9),
                ]), chunk: chunk(4_000, 9_000))
        XCTAssertEqual(assembler.words.map(\.word), ["Hello", "team", "again"])
        XCTAssertEqual(assembler.words.map(\.startMs), [100, 4_200, 4_700], "absolute recording times")
    }

    func testApplySynthesizesLivePreviewWordsForTextOnlyResult() {
        var assembler = MeetingTranscriptAssembler()
        assembler.apply(result("Hello unified world."), chunk: chunk(4_000, 9_000))
        XCTAssertEqual(assembler.words.map(\.word), ["Hello", "unified", "world."])
        XCTAssertEqual(assembler.words.first?.startMs, 4_000)
        XCTAssertEqual(assembler.words.last?.endMs, 9_000)
    }

    func testApplyTrimsTextOnlyOverlapPrefix() {
        var assembler = MeetingTranscriptAssembler()
        assembler.apply(result("Hello team"), chunk: chunk(0, 5_000))
        assembler.apply(result("Team, again"), chunk: chunk(4_000, 9_000))
        XCTAssertEqual(assembler.words.map(\.word), ["Hello", "team", "again"])
        XCTAssertEqual(assembler.words.last?.startMs, 5_000)
        XCTAssertEqual(assembler.words.last?.endMs, 9_000)
    }

    func testApplyPreservesRepeatedPrefixForContiguousTextOnlyChunks() {
        var assembler = MeetingTranscriptAssembler()
        assembler.apply(result("yes"), chunk: chunk(0, 1_000))
        assembler.apply(result("yes please"), chunk: chunk(1_000, 3_000))
        XCTAssertEqual(assembler.words.map(\.word), ["yes", "yes", "please"])
        XCTAssertEqual(assembler.words[1].startMs, 1_000)
        XCTAssertEqual(assembler.words.last?.endMs, 3_000)
    }

    func testApplyIgnoresTextOnlyResultWithoutWords() {
        var assembler = MeetingTranscriptAssembler()
        assembler.apply(result(" \n\t "), chunk: chunk(0, 5_000))
        XCTAssertTrue(assembler.words.isEmpty)
    }

    func testParagraphsBreakAtPausesAndJoinPunctuation() {
        var assembler = MeetingTranscriptAssembler()
        assembler.apply(
            result(
                "",
                [
                    WordTimestamp(word: "Budget", startMs: 0, endMs: 400, confidence: 1),
                    WordTimestamp(word: "first", startMs: 450, endMs: 800, confidence: 1),
                    WordTimestamp(word: ".", startMs: 800, endMs: 820, confidence: 1),
                    WordTimestamp(word: "Then", startMs: 4_000, endMs: 4_300, confidence: 1),
                    WordTimestamp(word: "hiring", startMs: 4_350, endMs: 4_800, confidence: 1),
                ]), chunk: chunk(10_000, 15_000))
        XCTAssertEqual(
            assembler.paragraphs(),
            [
                MeetingLiveParagraph(startMs: 10_000, text: "Budget first."),
                MeetingLiveParagraph(startMs: 14_000, text: "Then hiring"),
            ])
    }
}
