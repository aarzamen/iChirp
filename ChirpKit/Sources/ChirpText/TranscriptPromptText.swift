// Text shaping for language-model input (M4). `TextChunker` is ported from MacParakeet (GPL-3.0):
// Sources/MacParakeetCore/Services/LLM/InProcessLLMClient.swift @ bbae9e0e (`split`, `preferredChunkBoundary`,
// `skipLeadingWhitespace`). Changes: it splits the transcript alone (upstream split the joined chat messages), also
// prefers a line break before a sentence end, and never drops text: the chunks joined back together hold every
// non-whitespace character of the input. `TranscriptPromptFormatter` and `TranscriptCitationParser` are new.

import ChirpCore
import Foundation

/// Turns a transcript into model input.
public enum TranscriptPromptFormatter {
    /// One line per segment, `[mm:ss] Speaker 1: text` (`[h:mm:ss]` past an hour), with the roster's current speaker
    /// labels. Without segments, the transcript's display text. Timestamps let Ask cite moments that seek the player.
    public static func timestampedText(for transcription: Transcription) -> String {
        guard let segments = transcription.transcriptSegments, !segments.isEmpty else {
            return transcription.displayText
        }
        let roster = Dictionary(
            (transcription.speakers ?? []).map { ($0.id, $0.label) }, uniquingKeysWith: { first, _ in first })
        return
            segments
            .compactMap { segment -> String? in
                let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }
                let label = segment.speakerId.flatMap { roster[$0] } ?? segment.speakerLabel
                let stamp = "[\(timestamp(milliseconds: segment.startMs))]"
                return label.isEmpty ? "\(stamp) \(text)" : "\(stamp) \(label): \(text)"
            }
            .joined(separator: "\n")
    }

    /// `mm:ss`, or `h:mm:ss` from one hour.
    public static func timestamp(milliseconds: Int) -> String {
        let totalSeconds = max(0, milliseconds) / 1000
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

/// Splits long text into chunks of at most `maxCharacters`, preferring paragraph breaks, then line breaks, then
/// sentence ends, and never losing text.
public enum TextChunker {
    public static func split(_ text: String, maxCharacters: Int) -> [String] {
        let limit = max(1, maxCharacters)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed.isEmpty ? [] : [trimmed] }

        var chunks: [String] = []
        var cursor = trimmed.startIndex
        while cursor < trimmed.endIndex {
            let hardEnd = trimmed.index(cursor, offsetBy: limit, limitedBy: trimmed.endIndex) ?? trimmed.endIndex
            let end =
                hardEnd == trimmed.endIndex
                ? hardEnd
                : preferredChunkBoundary(in: cursor..<hardEnd, text: trimmed) ?? hardEnd
            let chunk = String(trimmed[cursor..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !chunk.isEmpty {
                chunks.append(chunk)
            }
            cursor = skipLeadingWhitespace(from: end, in: trimmed)
        }
        return chunks
    }

    /// The last paragraph break, else line break, else sentence end in `range`, in its second half so chunks do not
    /// get tiny; nil means cut at the hard limit.
    static func preferredChunkBoundary(in range: Range<String.Index>, text: String) -> String.Index? {
        let length = text.distance(from: range.lowerBound, to: range.upperBound)
        let floor = text.index(range.lowerBound, offsetBy: length / 2)
        let upperHalf = floor..<range.upperBound
        if let paragraphBreak = text.range(of: "\n\n", options: .backwards, range: upperHalf) {
            return paragraphBreak.upperBound
        }
        if let lineBreak = text.range(of: "\n", options: .backwards, range: upperHalf) {
            return lineBreak.upperBound
        }
        var cursor = range.upperBound
        while cursor > floor {
            let punctuationIndex = text.index(before: cursor)
            if isSentenceTerminator(text[punctuationIndex]) {
                let boundary = text.index(after: punctuationIndex)
                if boundary == text.endIndex || boundary == range.upperBound || text[boundary].isWhitespace {
                    return boundary
                }
            }
            cursor = punctuationIndex
        }
        return nil
    }

    private static func isSentenceTerminator(_ character: Character) -> Bool {
        character == "." || character == "!" || character == "?"
    }

    private static func skipLeadingWhitespace(from index: String.Index, in text: String) -> String.Index {
        var cursor = index
        while cursor < text.endIndex, text[cursor].isWhitespace {
            cursor = text.index(after: cursor)
        }
        return cursor
    }
}

/// A moment an answer cites, e.g. `[04:06]`, resolved to a segment of the transcript.
public struct TranscriptCitation: Sendable, Equatable {
    /// The text as written in the answer, e.g. "04:06".
    public var label: String
    /// Where to seek the player: the start of the cited segment.
    public var startMs: Int

    public init(label: String, startMs: Int) {
        self.label = label
        self.startMs = startMs
    }
}

/// Finds `[mm:ss]` / `[h:mm:ss]` citations in a model's answer and keeps only those that point at a real segment
/// start (a model can invent timestamps; an invented one is dropped, never guessed).
public enum TranscriptCitationParser {
    public static func citations(in answer: String, transcription: Transcription) -> [TranscriptCitation] {
        // The prompt shows each segment's start in whole seconds; map that back to the segment's exact start.
        let starts = Dictionary(
            (transcription.transcriptSegments ?? []).map { ($0.startMs / 1000, $0.startMs) },
            uniquingKeysWith: { min($0, $1) })
        guard !starts.isEmpty else { return [] }
        let pattern = #"\[(\d{1,2}:)?(\d{1,2}):(\d{2})\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(answer.startIndex..., in: answer)
        var seen = Set<Int>()
        var result: [TranscriptCitation] = []
        for match in regex.matches(in: answer, range: range) {
            guard let whole = Range(match.range, in: answer) else { continue }
            let label = String(answer[whole].dropFirst().dropLast())
            let parts = label.split(separator: ":").compactMap { Int($0) }
            let seconds = parts.reduce(0) { $0 * 60 + $1 }
            guard let startMs = starts[seconds], seen.insert(seconds).inserted else { continue }
            result.append(TranscriptCitation(label: label, startMs: startMs))
        }
        return result
    }
}
