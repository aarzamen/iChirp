import ChirpCore
import ChirpText
import Foundation
import NaturalLanguage

/// The text a structure run reads, with a map from character ranges back to transcript words and audio time.
///
/// Built from the transcript's word stream when it has word timings (`Transcription.text(.heard)`: the engine's
/// words with the person's corrections, joined by single spaces, so every character range maps to words and
/// milliseconds: tap a field → the player seeks); otherwise from its text (documents, pasted notes), with character
/// ranges only. A corrected passage is one word whose time is the envelope of the words it replaced (plan 025).
public struct StructuredSourceText: Sendable, Equatable {
    public let text: String
    /// UTF-16 range of each word in `text`, parallel to `words`.
    public let wordRanges: [Range<Int>]
    public let words: [WordTimestamp]
    /// Each kept word's index in the transcript's `wordTimestamps` (blank words are skipped); for a corrected passage,
    /// the first of the words it replaced.
    public let wordIndices: [Int]
    /// The engine words each kept word stands for: one, or every word a correction replaced (plan 025).
    public let transcriptWordRanges: [Range<Int>]

    public init(text: String) {
        self.text = text
        wordRanges = []
        words = []
        wordIndices = []
        transcriptWordRanges = []
    }

    public init(words: [WordTimestamp]) {
        self.init(words: words, wordRanges: words.indices.map { $0..<($0 + 1) })
    }

    /// `words` (the stream), each standing for `wordRanges[i]` of the engine's words.
    init(words: [WordTimestamp], wordRanges sourceRanges: [Range<Int>]) {
        var text = ""
        var ranges: [Range<Int>] = []
        var kept: [WordTimestamp] = []
        var indices: [Int] = []
        var covered: [Range<Int>] = []
        for (index, word) in words.enumerated() {
            let trimmed = word.word.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if !text.isEmpty { text += " " }
            let start = text.utf16.count
            text += trimmed
            ranges.append(start..<text.utf16.count)
            kept.append(word)
            let source = sourceRanges.indices.contains(index) ? sourceRanges[index] : index..<(index + 1)
            indices.append(source.lowerBound)
            covered.append(source)
        }
        self.text = text
        wordRanges = ranges
        self.words = kept
        wordIndices = indices
        transcriptWordRanges = covered
    }

    /// The word stream (with the person's corrections) when the transcript has word timings, else its text as heard.
    public init(transcription: Transcription) {
        let heard = transcription.text(.heard)
        if heard.hasWordTimings {
            self.init(words: heard.words, wordRanges: heard.tokens.map(\.wordRange))
        } else {
            self.init(text: heard.plainText)
        }
    }

    /// Sentence ranges (UTF-16), in order, skipping blank ones.
    public func sentenceRanges() -> [Range<Int>] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var ranges: [Range<Int>] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let sentence = text[range].trimmingCharacters(in: .whitespacesAndNewlines)
            if !sentence.isEmpty {
                let nsRange = NSRange(range, in: text)
                ranges.append(nsRange.location..<(nsRange.location + nsRange.length))
            }
            return true
        }
        return ranges
    }

    public func substring(_ range: Range<Int>) -> String {
        (text as NSString).substring(with: NSRange(location: range.lowerBound, length: range.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The evidence span for a character range: the words it touches and their audio time. A corrected passage counts
    /// whole: its every replaced word and its time envelope.
    public func span(for range: Range<Int>) -> StructuredSourceSpan {
        let touching = wordRanges.indices.filter { wordRanges[$0].overlaps(range) }
        guard let first = touching.first, let last = touching.last else {
            return StructuredSourceSpan(characterStart: range.lowerBound, characterEnd: range.upperBound)
        }
        return StructuredSourceSpan(
            characterStart: range.lowerBound, characterEnd: range.upperBound,
            wordStart: transcriptWordRanges[first].lowerBound, wordEnd: transcriptWordRanges[last].upperBound,
            startMs: words[first].startMs, endMs: words[last].endMs)
    }
}
