import ChirpCore
import FluidAudio
import XCTest

@testable import ChirpEngineFluidAudio

/// The engine keeps an internal copy of upstream `STTWordTimingBuilder` because this target must not depend on
/// ChirpText. These fixed token lists pin the behavior both copies must share: ChirpText's `WordTimingBuilder`
/// tests use the same inputs and expectations, so a divergence shows up as a failure in one of the two suites.
final class WordTimingParityTests: XCTestCase {
    private func timing(_ token: String, _ start: Double, _ end: Double, _ confidence: Float) -> TokenTiming {
        TokenTiming(token: token, tokenId: 0, startTime: start, endTime: end, confidence: confidence)
    }

    func testFixedTokenListMergesOnSentencePieceBoundaries() {
        let words = WordTimingBuilder.words(from: [
            timing("▁Hello", 0.00, 0.30, 0.9),
            timing(",", 0.30, 0.34, 0.7),
            timing("▁wor", 0.50, 0.62, 0.8),
            timing("ld", 0.62, 0.80, 1.0),
            timing(".", 0.80, 0.84, 0.6),
        ])

        XCTAssertEqual(words.map(\.word), ["Hello,", "world."])
        XCTAssertEqual(words.map(\.startMs), [0, 500])
        XCTAssertEqual(words.map(\.endMs), [340, 840])
        XCTAssertEqual(words[0].confidence, 0.8, accuracy: 0.0001)
        XCTAssertEqual(words[1].confidence, 0.8, accuracy: 0.0001)
        XCTAssertTrue(words.allSatisfy { $0.speakerId == nil })
    }

    func testStandaloneBoundaryTokenEndsTheWordAndBlankTokensAreDropped() {
        let words = WordTimingBuilder.words(from: [
            timing("▁improve", 0.00, 0.12, 0.9),
            timing("▁", 0.12, 0.16, 0.9),
            timing("based", 0.16, 0.28, 0.9),
            timing("▁on", 0.28, 0.40, 0.9),
        ])

        XCTAssertEqual(words.map(\.word), ["improve", "based", "on"])
        XCTAssertEqual(words.map(\.startMs), [0, 160, 280])
        XCTAssertEqual(words.map(\.endMs), [120, 280, 400])
    }

    func testNilOrEmptyTimingsProduceNoWords() {
        XCTAssertTrue(WordTimingBuilder.words(from: nil).isEmpty)
        XCTAssertTrue(WordTimingBuilder.words(from: []).isEmpty)
    }
}
