import ChirpCore
import XCTest

@testable import ChirpText

/// Plan 025 Step A3: `FileTranscriptSegments.joinedText` (port of upstream `KnowledgeSegmenter.joinedTokenText`) joins
/// tokens exactly as `materialize` joins a segment's words, so a corrected segment reads like a stored one.
final class FileTranscriptSegmentsTests: XCTestCase {
    func testJoinedTextMatchesMaterializedSegmentText() {
        let texts = [
            "Hello", ",", " world", "(", "aside", ")", "it", "'s", "fine", ".", "\u{201C}", "Quote", "\u{201D}",
            "and", "  ", "more", "text", "here", "!", "Then", "a", "longer", "run", "of", "words", "that", "goes",
            "past", "the", "minimum", "segment", "length", "so", "it", "splits", ".",
        ]
        let words = texts.enumerated().map { index, text in
            WordTimestamp(
                word: text, startMs: index * 300, endMs: index * 300 + 250, confidence: 1,
                speakerId: index < 20 ? "S1" : "S2")
        }
        let segments = FileTranscriptSegments.materialize(words: words)
        XCTAssertGreaterThan(segments.count, 1)
        for segment in segments {
            let range = segment.wordRange.startIndex..<segment.wordRange.endIndexExclusive
            XCTAssertEqual(FileTranscriptSegments.joinedText(words[range].map(\.word)), segment.text)
        }
        XCTAssertEqual(FileTranscriptSegments.joinedText(["", "  "]), "")
        XCTAssertEqual(FileTranscriptSegments.joinedText(["a", "visit.\n\nNew", "line"]), "a visit.\n\nNew line")
    }
}
