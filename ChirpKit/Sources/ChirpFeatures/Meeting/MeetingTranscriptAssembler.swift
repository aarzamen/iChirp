// Ported from MacParakeet (GPL-3.0): Sources/MacParakeetCore/Services/MeetingRecording/MeetingTranscriptAssembler.swift @ bbae9e0e
// Changes: one source (the iPhone microphone), so no per-source maps, speaker ids or realtime diarization segments;
// words keep absolute recording times (no origin normalization). Kept: offsetting chunk words by the chunk start,
// de-duplicating by absolute `endMs` against the last committed word, synthesized evenly spaced words (with the
// overlap-prefix trim) when an engine returns text without word timings, and the punctuation-aware text join.

import ChirpCore
import Foundation

/// Builds the display-only live transcript of a meeting from its live-preview chunks, applied in recording order.
public struct MeetingTranscriptAssembler: Sendable {
    private static let syntheticOverlapAnchorLength = 6

    public private(set) var words: [WordTimestamp] = []
    private var lastCommittedEndMs: Int?

    public init() {}

    public mutating func reset() {
        words = []
        lastCommittedEndMs = nil
    }

    /// Adds one chunk's result: words are shifted by `chunk.startMs`; any word ending at or before the last committed
    /// word is a repeat from an overlap and is dropped.
    public mutating func apply(_ result: SpeechResult, chunk: MeetingAudioChunk) {
        let cutoff = lastCommittedEndMs
        let offset = Self.offsetWords(from: result, chunk: chunk, committedWords: words, committedThroughMs: cutoff)
        let fresh = offset.filter { word in
            guard let cutoff else { return true }
            return word.endMs > cutoff
        }
        guard !fresh.isEmpty else { return }
        words.append(contentsOf: fresh)
        lastCommittedEndMs = fresh.last?.endMs
    }

    /// The words joined as text.
    public var text: String { Self.transcriptText(from: words) }

    /// Paragraphs for the Meeting screen: a new one after a pause of `gapMs` or more.
    public func paragraphs(gapMs: Int = 2_000) -> [MeetingLiveParagraph] {
        var result: [MeetingLiveParagraph] = []
        var current: [WordTimestamp] = []
        for word in words {
            if let last = current.last, word.startMs - last.endMs >= gapMs {
                let text = Self.transcriptText(from: current)
                result.append(MeetingLiveParagraph(startMs: current[0].startMs, text: text))
                current = []
            }
            current.append(word)
        }
        if let first = current.first {
            result.append(MeetingLiveParagraph(startMs: first.startMs, text: Self.transcriptText(from: current)))
        }
        return result
    }

    private static func offsetWords(
        from result: SpeechResult, chunk: MeetingAudioChunk, committedWords: [WordTimestamp], committedThroughMs: Int?
    ) -> [WordTimestamp] {
        if !result.words.isEmpty {
            return result.words.map {
                WordTimestamp(
                    word: $0.word, startMs: $0.startMs + chunk.startMs, endMs: $0.endMs + chunk.startMs,
                    confidence: $0.confidence)
            }
        }
        return synthesizeWords(
            from: result.text, chunk: chunk, committedWords: committedWords, committedThroughMs: committedThroughMs)
    }

    private static func synthesizeWords(
        from text: String, chunk: MeetingAudioChunk, committedWords: [WordTimestamp], committedThroughMs: Int?
    ) -> [WordTimestamp] {
        let rawTokens = text.split { $0.isWhitespace }.map(String.init)
        let hasTemporalOverlap = committedThroughMs.map { $0 > chunk.startMs } ?? false
        let tokens = hasTemporalOverlap ? trimOverlappingPrefix(rawTokens, committedWords: committedWords) : rawTokens
        guard !tokens.isEmpty else { return [] }
        let startBoundary = committedThroughMs.map { max(chunk.startMs, min($0, chunk.endMs)) } ?? chunk.startMs
        guard startBoundary < chunk.endMs else { return [] }
        let durationMs = max(chunk.endMs - startBoundary, tokens.count)
        return tokens.enumerated().map { index, token in
            WordTimestamp(
                word: token,
                startMs: startBoundary + (durationMs * index / tokens.count),
                endMs: startBoundary + (durationMs * (index + 1) / tokens.count),
                confidence: 0)
        }
    }

    private static func trimOverlappingPrefix(_ tokens: [String], committedWords: [WordTimestamp]) -> [String] {
        guard !tokens.isEmpty, !committedWords.isEmpty else { return tokens }
        let normalizedTokens = tokens.map(normalizeOverlapToken)
        let normalizedCommitted = committedWords.suffix(syntheticOverlapAnchorLength).map {
            normalizeOverlapToken($0.word)
        }
        var overlap = min(normalizedTokens.count, normalizedCommitted.count)
        while overlap > 0 {
            if normalizedCommitted.suffix(overlap).elementsEqual(normalizedTokens.prefix(overlap)) {
                return Array(tokens.dropFirst(overlap))
            }
            overlap -= 1
        }
        return tokens
    }

    private static func normalizeOverlapToken(_ token: String) -> String {
        let trimmed = token.trimmingCharacters(in: overlapTrimSet)
        return trimmed.isEmpty ? token.lowercased() : trimmed.lowercased()
    }

    private static let overlapTrimSet = CharacterSet.punctuationCharacters.union(.symbols)

    static func transcriptText(from words: [WordTimestamp]) -> String {
        var parts: [String] = []
        parts.reserveCapacity(words.count)
        for word in words {
            let token = word.word.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else { continue }
            if parts.isEmpty || shouldAttachWithoutLeadingSpace(token) {
                parts.append(token)
            } else {
                parts.append(" \(token)")
            }
        }
        return parts.joined()
    }

    private static func shouldAttachWithoutLeadingSpace(_ token: String) -> Bool {
        guard let first = token.first else { return false }
        return ",.!?;:%)]}".contains(first)
    }
}

/// One live paragraph on the Meeting screen: where it starts in the recording and its text.
public struct MeetingLiveParagraph: Sendable, Equatable, Identifiable {
    public var id: Int { startMs }
    public let startMs: Int
    public let text: String

    public init(startMs: Int, text: String) {
        self.startMs = startMs
        self.text = text
    }
}
