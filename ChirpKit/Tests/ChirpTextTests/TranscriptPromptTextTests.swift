import ChirpCore
import XCTest

@testable import ChirpText

final class TranscriptPromptTextTests: XCTestCase {
    private func word(_ text: String, _ startMs: Int, _ speaker: String? = nil) -> WordTimestamp {
        WordTimestamp(word: text, startMs: startMs, endMs: startMs + 400, confidence: 0.9, speakerId: speaker)
    }

    /// Three paragraphs: S1 at 0:04, S2 at 1:02:05, and a speaker-less word after a pause.
    private func timedRow() -> Transcription {
        var row = Transcription(fileName: "synthetic.m4a", status: .completed)
        row.wordTimestamps = [
            word("Hello", 4_000, "S1"), word("there.", 4_500, "S1"),
            word("Late", 3_725_000, "S2"), word("remark.", 3_725_500, "S2"),
            word("No", 3_730_000), word("speaker.", 3_730_500),
        ]
        row.rawTranscript = "Hello there. Late remark. No speaker."
        row.speakers = [SpeakerInfo(id: "S1", label: "Dana"), SpeakerInfo(id: "S2", label: "Speaker 2")]
        return row
    }

    func testModelInputHasOneLinePerParagraphWithTheCurrentRosterNames() {
        XCTAssertEqual(
            TranscriptPromptFormatter.modelInput(timedRow().text(.shown(.raw))),
            "[00:04] Dana: Hello there.\n[1:02:05] Speaker 2: Late remark.\n[1:02:10] No speaker.")
    }

    /// Review R2-1 / R4-21: segments the pipelines store say "Unknown Speaker" for words without a speaker; the model
    /// never sees that label, and a row without a roster has no names at all.
    func testModelInputNeverSaysUnknownSpeaker() {
        var row = Transcription(sourceType: .dictation, fileName: "dictation", status: .completed)
        row.wordTimestamps = [word("Patient", 0), word("stable.", 500)]
        row.rawTranscript = "Patient stable."
        row.transcriptSegments = FileTranscriptSegments.materialize(words: row.wordTimestamps!, speakers: nil)
        XCTAssertEqual(row.transcriptSegments?.first?.speakerLabel, "Unknown Speaker")

        let input = TranscriptPromptFormatter.modelInput(row.text(.shown(.raw)))
        XCTAssertEqual(input, "[00:00] Patient stable.")
        XCTAssertFalse(input.contains("Unknown Speaker"))
    }

    /// Review R2-1 / R4-1: in Clean, the model reads the clean text (custom words, filler removal), with the times of
    /// the words it came from.
    func testCleanModelInputCarriesTheCleanTextOnTimedLines() {
        var row = Transcription(fileName: "synthetic.m4a", status: .completed)
        row.wordTimestamps = [
            word("Um,", 0), word("start", 300), word("zarelto", 600), word("daily.", 900),
            word("Recheck", 5_000), word("in", 5_300), word("2.5", 5_600), word("weeks.", 5_900),
        ]
        row.rawTranscript = "Um, start zarelto daily. Recheck in 2.5 weeks."
        row.cleanTranscript = "Start Xarelto daily. Recheck in 2.5 weeks."
        XCTAssertEqual(
            TranscriptPromptFormatter.modelInput(row.text(.shown(.clean))),
            "[00:00] Start Xarelto daily.\n[00:05] Recheck in 2.5 weeks.")
        XCTAssertEqual(
            TranscriptPromptFormatter.modelInput(row.text(.shown(.raw))),
            "[00:00] Um, start zarelto daily.\n[00:05] Recheck in 2.5 weeks.")
    }

    func testWithoutWordTimingsTheViewTextIsUsedAsItIs() {
        var row = Transcription(sourceType: .text, fileName: "note", status: .completed)
        row.rawTranscript = "Typed note.\n\nSecond paragraph."
        XCTAssertEqual(TranscriptPromptFormatter.modelInput(row.text(.shown(.raw))), "Typed note.\n\nSecond paragraph.")
        row.cleanTranscript = "Clean words."
        XCTAssertEqual(TranscriptPromptFormatter.modelInput(row.text(.shown(.clean))), "Clean words.")
        XCTAssertEqual(TranscriptPromptFormatter.modelInput(row.text(.shown(.raw))), "Typed note.\n\nSecond paragraph.")
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

    /// Review R4-16: "2.5 mg" whose "." is the window's last character used to split into "2." and "5 mg".
    func testChunkerNeverSplitsADecimalAtTheWindowEdge() {
        let prefix = String(repeating: "word ", count: 18) + "dose was 2"  // 100 characters
        let text = prefix + ".5 mg daily and more words follow here"
        XCTAssertEqual(prefix.count, 100)
        let chunks = TextChunker.split(text, maxCharacters: 101)
        XCTAssertFalse(chunks[0].hasSuffix("2."), "split inside 2.5: \(chunks)")
        XCTAssertTrue(chunks.contains { $0.contains("2.5 mg") }, "\(chunks)")
    }

    /// Review R4-16, property: for any text whose words fit the limit, no chunk boundary falls inside a word or a
    /// number, every chunk fits, and the chunks hold every word, in order.
    func testChunkerNeverSplitsAWordOrANumberProperty() {
        var generator = SplitMix64(seed: 0x5EED_2024_0008)
        let vocabulary = [
            "2.5", "mg", "120/80", "1,000", "0.125", "units", "BP", "was", "the", "dose.", "Recheck", "in", "3.75",
            "weeks!", "Is", "it", "10.5?", "q.i.d.", "e.g.", "Dr.", "Xarelto", "…", "—", "potassium", "4.2.",
        ]
        let separators = [" ", " ", " ", " ", "\n", "\n\n", "  "]
        for round in 0..<300 {
            let count = Int(generator.next() % 200) + 1
            var text = ""
            var expected: [String] = []
            for index in 0..<count {
                let token = vocabulary[Int(generator.next() % UInt64(vocabulary.count))]
                expected.append(token)
                text += token
                if index < count - 1 { text += separators[Int(generator.next() % UInt64(separators.count))] }
            }
            let limit = Int(generator.next() % 120) + 10  // every word fits: "potassium" is the longest
            let chunks = TextChunker.split(text, maxCharacters: limit)
            XCTAssertTrue(chunks.allSatisfy { $0.count <= limit }, "round \(round) limit \(limit)")
            let rejoined = chunks.flatMap { $0.split(whereSeparator: \.isWhitespace).map(String.init) }
            XCTAssertEqual(rejoined, expected, "round \(round) limit \(limit): a word or number was split")
        }
    }

    func testCitationsKeepOnlyRealLineStarts() {
        var row = Transcription(fileName: "synthetic.m4a", status: .completed)
        row.wordTimestamps = [word("a.", 12_500, "S1"), word("b.", 3_725_000, "S1")]
        row.rawTranscript = "a. b."
        let shown = row.text(.shown(.raw))
        let citations = TranscriptCitationParser.citations(
            in: "See [00:12] and [1:02:05], again [00:12], and invented [07:00] or [0:61].", text: shown)
        XCTAssertEqual(
            citations,
            [
                TranscriptCitation(label: "00:12", startMs: 12_500),
                TranscriptCitation(label: "1:02:05", startMs: 3_725_000),
            ])
        var untimed = Transcription(fileName: "x")
        untimed.rawTranscript = "No timestamps here."
        XCTAssertEqual(TranscriptCitationParser.citations(in: "[00:12]", text: untimed.text(.shown(.raw))), [])
    }
}

/// A small deterministic generator for the property test (the same texts on every run).
private struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
