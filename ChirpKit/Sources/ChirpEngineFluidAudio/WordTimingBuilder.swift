// Ported from MacParakeet (GPL-3.0): Sources/MacParakeetCore/STT/STTWordTimingBuilder.swift @ bbae9e0e
// Internal copy (this target must not depend on ChirpText); emits ChirpCore `WordTimestamp`. Keep in step with
// ChirpText's `WordTimingBuilder`; `WordTimingParityTests` pins the shared behavior.

import ChirpCore
import FluidAudio
import Foundation

/// Merges FluidAudio token timings into words on the SentencePiece `▁` boundary, averaging token confidences.
enum WordTimingBuilder {
    static func words(from tokenTimings: [TokenTiming]?) -> [WordTimestamp] {
        guard let tokenTimings, !tokenTimings.isEmpty else { return [] }

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
                // A SentencePiece boundary emitted as its own token still terminates the preceding word.
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
