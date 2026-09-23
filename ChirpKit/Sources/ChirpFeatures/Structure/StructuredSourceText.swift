import ChirpCore
import Foundation
import NaturalLanguage

/// The text a structure run reads, with a map from character ranges back to transcript words and audio time.
///
/// Built from the transcript's word timestamps when it has them (words joined by single spaces, so every character
/// range maps to words and milliseconds: tap a field → the player seeks); otherwise from its text (documents, pasted
/// notes), with character ranges only.
public struct StructuredSourceText: Sendable, Equatable {
    public let text: String
    /// UTF-16 range of each word in `text`, parallel to `words`.
    public let wordRanges: [Range<Int>]
    public let words: [WordTimestamp]
    /// Each kept word's index in the transcript's `wordTimestamps` (blank words are skipped).
    public let wordIndices: [Int]

    public init(text: String) {
        self.text = text
        wordRanges = []
        words = []
        wordIndices = []
    }

    public init(words: [WordTimestamp]) {
        var text = ""
        var ranges: [Range<Int>] = []
        var kept: [WordTimestamp] = []
        var indices: [Int] = []
        for (index, word) in words.enumerated() {
            let trimmed = word.word.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if !text.isEmpty { text += " " }
            let start = text.utf16.count
            text += trimmed
            ranges.append(start..<text.utf16.count)
            kept.append(word)
            indices.append(index)
        }
        self.text = text
        wordRanges = ranges
        self.words = kept
        wordIndices = indices
    }

    /// Words when the transcript has them, else its display text.
    public init(transcription: Transcription) {
        if let words = transcription.wordTimestamps, !words.isEmpty {
            self.init(words: words)
        } else {
            self.init(text: transcription.displayText)
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

    /// The evidence span for a character range: the words it touches and their audio time.
    public func span(for range: Range<Int>) -> StructuredSourceSpan {
        let touching = wordRanges.indices.filter { wordRanges[$0].overlaps(range) }
        guard let first = touching.first, let last = touching.last else {
            return StructuredSourceSpan(characterStart: range.lowerBound, characterEnd: range.upperBound)
        }
        return StructuredSourceSpan(
            characterStart: range.lowerBound, characterEnd: range.upperBound, wordStart: wordIndices[first],
            wordEnd: wordIndices[last] + 1, startMs: words[first].startMs, endMs: words[last].endMs)
    }
}
