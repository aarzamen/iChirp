// Ported from MacParakeet (GPL-3.0): Sources/MacParakeetCore/STT/STTWordTimingBuilder.swift @ bbae9e0e
// Changes: FluidAudio-free — takes `[TokenTimingInput]` instead of `[TokenTiming]?`, returns
// `[WordTimestamp]` (ChirpCore) instead of `[TimestampedWord]`, and is public.

import ChirpCore
import Foundation

/// One recognized token's timing, decoupled from any specific STT engine's token type.
public struct TokenTimingInput: Sendable {
    public var token: String
    public var startTime: TimeInterval
    public var endTime: TimeInterval
    public var confidence: Float

    public init(token: String, startTime: TimeInterval, endTime: TimeInterval, confidence: Float) {
        self.token = token
        self.startTime = startTime
        self.endTime = endTime
        self.confidence = confidence
    }
}

/// Merges sub-word token timings into word-level timestamps on the SentencePiece `▁` boundary.
public enum WordTimingBuilder {
    public static func words(from tokenTimings: [TokenTimingInput]) -> [WordTimestamp] {
        guard !tokenTimings.isEmpty else { return [] }

        var words: [WordTimestamp] = []
        var currentWord = ""
        var currentStartTime: TimeInterval?
        var currentEndTime: TimeInterval = 0
        var currentConfidences: [Float] = []

        func flushCurrentWord() {
            guard !currentWord.isEmpty, let startTime = currentStartTime else { return }
            let averageConfidence =
                currentConfidences.isEmpty
                ? 0.0
                : (currentConfidences.reduce(0, +) / Float(currentConfidences.count))

            words.append(
                WordTimestamp(
                    word: currentWord,
                    startMs: Int((startTime * 1_000).rounded()),
                    endMs: Int((currentEndTime * 1_000).rounded()),
                    confidence: Double(averageConfidence)
                )
            )

            currentWord = ""
            currentStartTime = nil
            currentEndTime = 0
            currentConfidences.removeAll(keepingCapacity: true)
        }

        for timing in tokenTimings {
            let normalizedToken = timing.token.replacingOccurrences(of: "▁", with: " ")
            let startsNewWord = normalizedToken.first?.isWhitespace == true
            let trimmedToken = normalizedToken.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedToken.isEmpty else {
                // Multilingual Nemotron can emit the SentencePiece boundary as
                // its own token, so it still terminates the preceding word.
                if startsNewWord {
                    flushCurrentWord()
                }
                continue
            }

            if startsNewWord {
                flushCurrentWord()
                currentWord = trimmedToken
                currentStartTime = timing.startTime
                currentEndTime = timing.endTime
                currentConfidences = [timing.confidence]
            } else {
                if currentStartTime == nil {
                    currentStartTime = timing.startTime
                }
                currentWord += trimmedToken
                currentEndTime = timing.endTime
                currentConfidences.append(timing.confidence)
            }
        }

        flushCurrentWord()
        return words
    }
}
