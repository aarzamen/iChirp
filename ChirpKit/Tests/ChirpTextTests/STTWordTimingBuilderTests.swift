// Ported from MacParakeet (GPL-3.0): Tests/MacParakeetTests/STT/STTWordTimingBuilderTests.swift @ bbae9e0e
// Changes: `STTWordTimingBuilder.words(from: [TokenTiming]?)` → `WordTimingBuilder.words(from:
// [TokenTimingInput])`; `TokenTiming(token:tokenId:startTime:endTime:confidence:)` (FluidAudio) →
// `TokenTimingInput(token:startTime:endTime:confidence:)` (no `tokenId`).

@testable import ChirpText
import XCTest

final class STTWordTimingBuilderTests: XCTestCase {
    func testWordsGroupSentencePieceTokens() {
        let words = WordTimingBuilder.words(from: [
            TokenTimingInput(token: "▁hello", startTime: 0.10, endTime: 0.18, confidence: 0.8),
            TokenTimingInput(token: "world", startTime: 0.18, endTime: 0.36, confidence: 1.0),
            TokenTimingInput(token: "▁again", startTime: 0.50, endTime: 0.72, confidence: 0.9),
        ])

        XCTAssertEqual(words.count, 2)
        XCTAssertEqual(words[0].word, "helloworld")
        XCTAssertEqual(words[0].startMs, 100)
        XCTAssertEqual(words[0].endMs, 360)
        XCTAssertEqual(words[0].confidence, 0.9, accuracy: 0.0001)
        XCTAssertEqual(words[1].word, "again")
        XCTAssertEqual(words[1].startMs, 500)
        XCTAssertEqual(words[1].endMs, 720)
        XCTAssertEqual(words[1].confidence, 0.9, accuracy: 0.0001)
    }

    func testWordsIgnoreBlankTokens() {
        let words = WordTimingBuilder.words(from: [
            TokenTimingInput(token: "▁", startTime: 0, endTime: 0.08, confidence: 0.5),
            TokenTimingInput(token: "▁done", startTime: 0.16, endTime: 0.32, confidence: 0.95),
        ])

        XCTAssertEqual(words.count, 1)
        XCTAssertEqual(words[0].word, "done")
        XCTAssertEqual(words[0].startMs, 160)
        XCTAssertEqual(words[0].endMs, 320)
    }

    func testWordsPreserveStandaloneSentencePieceBoundary() {
        let words = WordTimingBuilder.words(from: [
            TokenTimingInput(token: "▁improve", startTime: 0.00, endTime: 0.12, confidence: 0.9),
            TokenTimingInput(token: "▁", startTime: 0.12, endTime: 0.16, confidence: 0.9),
            TokenTimingInput(token: "based", startTime: 0.16, endTime: 0.28, confidence: 0.9),
            TokenTimingInput(token: "▁on", startTime: 0.28, endTime: 0.40, confidence: 0.9),
        ])

        XCTAssertEqual(words.map(\.word), ["improve", "based", "on"])
        XCTAssertEqual(words.map(\.startMs), [0, 160, 280])
        XCTAssertEqual(words.map(\.endMs), [120, 280, 400])
    }

    func testWordsStartPlainFirstTokenAsWord() {
        let words = WordTimingBuilder.words(from: [
            TokenTimingInput(token: "hello", startTime: 0.04, endTime: 0.20, confidence: 0.7),
            TokenTimingInput(token: "▁world", startTime: 0.32, endTime: 0.48, confidence: 0.9),
        ])

        XCTAssertEqual(words.count, 2)
        XCTAssertEqual(words[0].word, "hello")
        XCTAssertEqual(words[0].startMs, 40)
        XCTAssertEqual(words[0].endMs, 200)
        XCTAssertEqual(words[1].word, "world")
        XCTAssertEqual(words[1].startMs, 320)
        XCTAssertEqual(words[1].endMs, 480)
    }

    func testWordsReturnEmptyForAllBlankTokens() {
        let words = WordTimingBuilder.words(from: [
            TokenTimingInput(token: "▁", startTime: 0.00, endTime: 0.04, confidence: 0.2),
            TokenTimingInput(token: " ", startTime: 0.04, endTime: 0.08, confidence: 0.3),
            TokenTimingInput(token: "\n", startTime: 0.08, endTime: 0.12, confidence: 0.4),
        ])

        XCTAssertTrue(words.isEmpty)
    }

    func testWordsAverageConfidenceAcrossMultipleTokens() {
        let words = WordTimingBuilder.words(from: [
            TokenTimingInput(token: "▁pro", startTime: 0.10, endTime: 0.18, confidence: 0.2),
            TokenTimingInput(token: "duc", startTime: 0.18, endTime: 0.26, confidence: 0.5),
            TokenTimingInput(token: "tion", startTime: 0.26, endTime: 0.40, confidence: 0.8),
        ])

        XCTAssertEqual(words.count, 1)
        XCTAssertEqual(words[0].word, "production")
        XCTAssertEqual(words[0].startMs, 100)
        XCTAssertEqual(words[0].endMs, 400)
        XCTAssertEqual(words[0].confidence, 0.5, accuracy: 0.0001)
    }
}
