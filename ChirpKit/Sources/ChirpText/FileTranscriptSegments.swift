// Ported from MacParakeet (GPL-3.0): Sources/MacParakeetCore/Utilities/KnowledgeSegmenter.swift @ bbae9e0e
// Changes: ported `materializeFileTranscriptSegments` only (renamed to `FileTranscriptSegments.materialize`
// — the search-index/FTS half of `KnowledgeSegmenter` is out of scope for M0/M1); dropped the
// `AudioSource` speaker-label fallback (not ported to iChirp), same as `TranscriptSegmenter`.

import ChirpCore
import Foundation

/// Materializes durable file/URL transcript segments from word timings, grouped into
/// knowledge-index-sized chunks (target 200–500 Unicode scalars) rather than the shorter
/// presentation segments `TranscriptSegmenter` produces.
public enum FileTranscriptSegments {
    private static let targetMinimumScalars = 200
    private static let targetMaximumScalars = 500

    public static func materialize(
        words: [WordTimestamp],
        speakers: [SpeakerInfo]? = nil,
        idGenerator: () -> UUID = { UUID() }
    ) -> [TranscriptSegmentRecord] {
        let usableIndices = words.indices.filter { usableText(words[$0].word) != nil }
        guard let firstUsableIndex = usableIndices.first else { return [] }
        var labels: [String: String] = [:]
        for speaker in speakers ?? [] where labels[speaker.id] == nil {
            labels[speaker.id] = speaker.label
        }
        var result: [TranscriptSegmentRecord] = []
        var startPosition = 0
        var currentText = ""
        var currentScalarCount = 0
        var currentSpeaker = words[firstUsableIndex].speakerId

        func append(endPositionExclusive: Int) {
            guard !currentText.isEmpty else { return }
            let firstIndex = usableIndices[startPosition]
            let lastIndex = usableIndices[endPositionExclusive - 1]
            let first = words[firstIndex]
            let last = words[lastIndex]
            let speakerLabel: String
            if let currentSpeaker {
                speakerLabel = labels[currentSpeaker] ?? currentSpeaker
            } else {
                speakerLabel = "Unknown Speaker"
            }
            result.append(
                TranscriptSegmentRecord(
                    id: idGenerator(),
                    startMs: first.startMs,
                    endMs: last.endMs,
                    speakerId: currentSpeaker,
                    speakerLabel: speakerLabel,
                    text: currentText,
                    wordRange: TranscriptSegmentWordRange(
                        startIndex: firstIndex,
                        endIndexExclusive: lastIndex + 1
                    )
                ))
        }

        for position in usableIndices.indices {
            let index = usableIndices[position]
            let word = words[index]
            guard let wordText = usableText(word.word) else { continue }
            let speakerChanged = word.speakerId != nil && word.speakerId != currentSpeaker
            let wordScalarCount = wordText.unicodeScalars.count
            let separator = tokenSeparator(
                before: wordText,
                rawToken: word.word,
                currentText: currentText
            )
            let candidateCount = currentScalarCount + separator.unicodeScalars.count + wordScalarCount
            if !currentText.isEmpty && (speakerChanged || candidateCount > targetMaximumScalars) {
                append(endPositionExclusive: position)
                currentText.removeAll(keepingCapacity: true)
                currentScalarCount = 0
                startPosition = position
                currentSpeaker = word.speakerId
            }

            let effectiveSeparator = tokenSeparator(
                before: wordText,
                rawToken: word.word,
                currentText: currentText
            )
            currentText += effectiveSeparator + wordText
            currentScalarCount += effectiveSeparator.unicodeScalars.count + wordScalarCount
            if let speakerId = word.speakerId { currentSpeaker = speakerId }
            let sentenceEnded = wordText.unicodeScalars.last.map(isSentenceTerminator) ?? false
            let nextPosition = position + 1
            let longGap =
                nextPosition < usableIndices.count
                && words[usableIndices[nextPosition]].startMs - word.endMs > 1_500
            let isLast = nextPosition == usableIndices.count
            if isLast || longGap || (sentenceEnded && currentScalarCount >= targetMinimumScalars) {
                append(endPositionExclusive: nextPosition)
                currentText.removeAll(keepingCapacity: true)
                currentScalarCount = 0
                if !isLast {
                    startPosition = nextPosition
                    currentSpeaker = words[usableIndices[nextPosition]].speakerId ?? currentSpeaker
                }
            }
        }
        return result
    }

    private static func usableText(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
            !trimmed.isEmpty
        else {
            return nil
        }
        return trimmed
    }

    private static func tokenSeparator(
        before token: String,
        rawToken: String,
        currentText: String
    ) -> String {
        guard !currentText.isEmpty else { return "" }
        if token.unicodeScalars.first.map(isClosingPunctuation) == true { return "" }
        let hasLeadingWhitespace = rawToken.unicodeScalars.first.map(isExplicitWhitespace) == true
        if token.unicodeScalars.first.map(isQuoteOrApostrophe) == true {
            return hasLeadingWhitespace ? " " : ""
        }
        if hasLeadingWhitespace { return " " }
        if currentText.unicodeScalars.last.map({
            isOpeningPunctuation($0) || isQuoteOrApostrophe($0)
        }) == true {
            return ""
        }
        return " "
    }

    private static func isClosingPunctuation(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.value {
        case 0x21, 0x25, 0x29, 0x2C, 0x2E, 0x3A, 0x3B, 0x3E, 0x3F,
            0x5D, 0x7D, 0x3001, 0x3002, 0xFF01, 0xFF0C, 0xFF0E, 0xFF1A, 0xFF1B,
            0xFF1F, 0xFF09, 0xFF3D, 0xFF5D:
            true
        default:
            false
        }
    }

    private static func isOpeningPunctuation(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.value {
        case 0x28, 0x3C, 0x5B, 0x7B, 0x3008, 0x300C, 0xFF08, 0xFF3B, 0xFF5B:
            true
        default:
            false
        }
    }

    private static func isQuoteOrApostrophe(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.value {
        case 0x22, 0x27, 0x2018, 0x2019, 0x201C, 0x201D:
            true
        default:
            false
        }
    }

    private static func isExplicitWhitespace(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.value {
        case 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20:
            true
        default:
            false
        }
    }

    private static func isSentenceTerminator(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.value {
        case 0x21, 0x2E, 0x3F, 0x3002, 0xFF01, 0xFF1F:
            true
        default:
            false
        }
    }
}
