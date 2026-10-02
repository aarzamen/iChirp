// Ported from MacParakeet (GPL-3.0): Sources/MacParakeetCore/TextProcessing/TranscriptParagraphBuilder.swift @ bbae9e0e
// Changes: `WordTimestamp` comes from ChirpCore; `buildWithWordRanges(from:)` (plan 024 Task 8) returns each paragraph
// with the half-open range of words it holds, so `TranscriptText` lines keep stable boundaries; `build(from:)` maps it.

import ChirpCore
import Foundation

/// A reading-oriented paragraph assembled from timestamped transcript words.
public struct TranscriptParagraph: Sendable, Equatable {
    public let startMs: Int
    public let endMs: Int
    public let text: String
    public let speakerId: String?

    public init(startMs: Int, endMs: Int, text: String, speakerId: String?) {
        self.startMs = startMs
        self.endMs = endMs
        self.text = text
        self.speakerId = speakerId
    }
}

/// Builds stable, human-readable paragraphs without changing stored transcript segments.
public enum TranscriptParagraphBuilder {
    private static let maximumSentenceCount = 3
    private static let maximumWordCount = 80
    private static let paragraphPauseMs = 2_500

    public static func build(from words: [WordTimestamp]) -> [TranscriptParagraph] {
        buildWithWordRanges(from: words).map(\.paragraph)
    }

    /// The same paragraphs as `build(from:)`, each with the half-open range of `words` it holds. The ranges cover
    /// every word exactly once, in order.
    public static func buildWithWordRanges(
        from words: [WordTimestamp]
    ) -> [(paragraph: TranscriptParagraph, wordRange: Range<Int>)] {
        guard let firstWord = words.first else { return [] }

        var paragraphs: [(paragraph: TranscriptParagraph, wordRange: Range<Int>)] = []
        var paragraphWords: [String] = []
        var paragraphFirstIndex = 0
        var paragraphStartMs = firstWord.startMs
        var paragraphEndMs = firstWord.endMs
        var paragraphSpeakerId = firstWord.speakerId
        var sentenceCount = 0

        func appendParagraph(endingBefore end: Int) {
            guard !paragraphWords.isEmpty else { return }
            paragraphs.append(
                (
                    TranscriptParagraph(
                        startMs: paragraphStartMs,
                        endMs: paragraphEndMs,
                        text: paragraphWords.joined(separator: " "),
                        speakerId: paragraphSpeakerId
                    ),
                    paragraphFirstIndex..<end
                )
            )
        }

        for (index, word) in words.enumerated() {
            let speakerChanged = word.speakerId != paragraphSpeakerId
            let pauseReached = word.startMs - paragraphEndMs >= paragraphPauseMs
            if !paragraphWords.isEmpty, speakerChanged || pauseReached {
                appendParagraph(endingBefore: index)
                paragraphWords.removeAll(keepingCapacity: true)
                paragraphFirstIndex = index
                paragraphStartMs = word.startMs
                paragraphSpeakerId = word.speakerId
                sentenceCount = 0
            }

            paragraphWords.append(word.word)
            paragraphEndMs = word.endMs

            if endsSentence(word.word) {
                sentenceCount += 1
            }

            guard sentenceCount >= maximumSentenceCount || paragraphWords.count >= maximumWordCount else {
                continue
            }

            appendParagraph(endingBefore: index + 1)
            paragraphWords.removeAll(keepingCapacity: true)
            paragraphFirstIndex = index + 1
            sentenceCount = 0

            if words.indices.contains(index + 1) {
                let nextWord = words[index + 1]
                paragraphStartMs = nextWord.startMs
                paragraphEndMs = nextWord.endMs
                paragraphSpeakerId = nextWord.speakerId
            }
        }

        appendParagraph(endingBefore: words.count)
        return paragraphs
    }

    private static func endsSentence(_ word: String) -> Bool {
        let trimmedWord = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let lastCharacter = trimmedWord.last else { return false }
        return lastCharacter == "." || lastCharacter == "!" || lastCharacter == "?"
    }
}
