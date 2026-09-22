import ChirpCore
import XCTest

@testable import ChirpText

final class TranscriptPromptTextTests: XCTestCase {
    private func segment(_ startMs: Int, _ speaker: String?, _ label: String, _ text: String) -> TranscriptSegmentRecord {
        TranscriptSegmentRecord(
            startMs: startMs, endMs: startMs + 1_000, speakerId: speaker, speakerLabel: label, text: text,
            wordRange: TranscriptSegmentWordRange(startIndex: 0, endIndexExclusive: 1))
    }

    func testTimestampedTextUsesTheCurrentRosterLabels() {
        var row = Transcription(fileName: "synthetic.m4a", status: .completed)
        row.transcriptSegments = [
            segment(4_000, "S1", "Speaker 1", "Hello there."),
            segment(3_725_000, "S2", "Speaker 2", "  Late remark. "),
            segment(3_726_000, nil, "", "No speaker."),
            segment(3_727_000, "S2", "Speaker 2", "   "),
        ]
        row.speakers = [SpeakerInfo(id: "S1", label: "Dana"), SpeakerInfo(id: "S2", label: "Speaker 2")]
        XCTAssertEqual(
            TranscriptPromptFormatter.timestampedText(for: row),
            "[00:04] Dana: Hello there.\n[1:02:05] Speaker 2: Late remark.\n[1:02:06] No speaker.")
    }

    func testWithoutSegmentsTheDisplayTextIsUsed() {
        var row = Transcription(fileName: "synthetic.m4a", status: .completed)
        row.rawTranscript = "raw words"
        row.cleanTranscript = "Clean words."
        XCTAssertEqual(TranscriptPromptFormatter.timestampedText(for: row), "Clean words.")
    }

    func testChunkerNeverLosesTextAndRespectsTheLimit() {
        let words = (1...3_000).map { "w\($0)" + ($0 % 17 == 0 ? "." : "") + ($0 % 101 == 0 ? "\n\n" : " ") }
        let text = words.joined()
        for limit in [50, 333, 1_000, 12_000] {
            let chunks = TextChunker.split(text, maxCharacters: limit)
            XCTAssertTrue(chunks.allSatisfy { $0.count <= limit }, "limit \(limit)")
            let rejoined = chunks.joined(separator: " ").filter { !$0.isWhitespace }
            XCTAssertEqual(rejoined, text.filter { !$0.isWhitespace }, "limit \(limit): text was lost")
        }
        XCTAssertEqual(TextChunker.split("   ", maxCharacters: 10), [])
        XCTAssertEqual(TextChunker.split("short", maxCharacters: 10), ["short"])
    }

    func testChunkerPrefersParagraphsThenSentences() {
        let text = String(repeating: "a", count: 60) + "\n\n" + String(repeating: "b", count: 60)
        XCTAssertEqual(TextChunker.split(text, maxCharacters: 100).first, String(repeating: "a", count: 60))
        let sentences = String(repeating: "x", count: 70) + ". " + String(repeating: "y", count: 70)
        XCTAssertEqual(TextChunker.split(sentences, maxCharacters: 100).first, String(repeating: "x", count: 70) + ".")
    }

    func testCitationsKeepOnlyRealSegmentStarts() {
        var row = Transcription(fileName: "synthetic.m4a", status: .completed)
        row.transcriptSegments = [segment(12_500, "S1", "Speaker 1", "a"), segment(3_725_000, "S1", "Speaker 1", "b")]
        let citations = TranscriptCitationParser.citations(
            in: "See [00:12] and [1:02:05], again [00:12], and invented [07:00] or [0:61].", transcription: row)
        XCTAssertEqual(
            citations,
            [TranscriptCitation(label: "00:12", startMs: 12_500), TranscriptCitation(label: "1:02:05", startMs: 3_725_000)])
        XCTAssertEqual(TranscriptCitationParser.citations(in: "[00:12]", transcription: Transcription(fileName: "x")), [])
    }
}
