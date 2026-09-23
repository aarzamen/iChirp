// Ported from Readback (owner's project): Sources/TTS/Chunker.swift @ 696cef6
// Changes: renamed `SpeechChunker`/`SpeechTextChunk`; the hard split follows the engine's `maxCharactersPerRequest`
// (companion 4 000, xAI 15 000) instead of a provider switch, and packing never exceeds it either (Readback could pack
// split pieces up to 2 500 even under a smaller cap); otherwise unchanged (NLTokenizer sentences, first chunk
// ≤ 500 characters for a quick first sound, then ≤ 2 500, never mid-sentence, paragraph ends tagged).

import Foundation
import NaturalLanguage

/// One piece of text for one synthesis call.
public struct SpeechTextChunk: Sendable, Equatable {
    public let text: String
    /// The chunk ends a paragraph: the player inserts a short silence after it.
    public let endsParagraph: Bool

    public init(text: String, endsParagraph: Bool) {
        self.text = text
        self.endsParagraph = endsParagraph
    }
}

/// Splits text for speech on sentence boundaries (speech-synthesis-plugin-v1 rule 5: chunking is the caller's job).
/// First chunk ≤ 500 characters (fast time to first audio), later ones ≤ 2 500. Never splits mid-sentence; a single
/// sentence longer than 2 500 goes alone; past the hard limit it is split at the nearest clause punctuation or space.
public enum SpeechChunker {
    public static let firstChunkLimit = 500
    public static let chunkLimit = 2_500
    public static let hardSplitLimit = 4_900

    /// `hardCap`: the engine's `maxCharactersPerRequest`; it tightens the hard split below 4 900 (never below 500).
    public static func chunk(_ text: String, hardCap: Int = hardSplitLimit) -> [SpeechTextChunk] {
        let hardLimit = min(hardSplitLimit, max(500, hardCap))
        var chunks: [SpeechTextChunk] = []
        for paragraph in splitParagraphs(text) {
            let pieces = pack(sentences(in: paragraph), isUtteranceStart: chunks.isEmpty, hardLimit: hardLimit)
            for (index, piece) in pieces.enumerated() {
                chunks.append(SpeechTextChunk(text: piece, endsParagraph: index == pieces.count - 1))
            }
        }
        return chunks
    }

    // MARK: - Paragraphs

    /// Blank lines always end a paragraph. A single newline ends one only when the line before it ends a sentence:
    /// hard-wrapped text (PDF pages) would otherwise turn every line into a paragraph pause. Wrapped lines are
    /// re-joined with spaces.
    private static let sentenceEnders: Set<Character> = [".", "!", "?", "…"]
    private static let trailingWrappers: Set<Character> = ["\"", "\u{201D}", "'", "\u{2019}", ")", "]"]

    private static func endsSentence(_ line: Substring) -> Bool {
        var rest = line[...]
        while let last = rest.last, trailingWrappers.contains(last) {
            rest = rest.dropLast()
        }
        guard let last = rest.last else { return false }
        return sentenceEnders.contains(last)
    }

    static func splitParagraphs(_ text: String) -> [String] {
        var paragraphs: [String] = []
        var current = ""
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        for (index, rawLine) in lines.enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                if !current.isEmpty {
                    paragraphs.append(current)
                    current = ""
                }
                continue
            }
            current = current.isEmpty ? line : current + " " + line
            if index < lines.count - 1, endsSentence(Substring(line)) {
                paragraphs.append(current)
                current = ""
            }
        }
        if !current.isEmpty { paragraphs.append(current) }
        return paragraphs
    }

    // MARK: - Sentences

    private static func sentences(in text: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var out: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let sentence = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !sentence.isEmpty { out.append(sentence) }
            return true
        }
        if out.isEmpty {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? [] : [trimmed]
        }
        return out
    }

    // MARK: - Packing

    private static func pack(_ sentences: [String], isUtteranceStart: Bool, hardLimit: Int) -> [String] {
        var result: [String] = []
        var current = ""

        func flush() {
            if !current.isEmpty {
                result.append(current)
                current = ""
            }
        }

        for sentence in sentences {
            for piece in splitOversized(sentence, hardLimit: hardLimit) {
                // Never above the engine's own limit (a hard cap under 2 500 tightens packing too).
                let limit = min((isUtteranceStart && result.isEmpty) ? firstChunkLimit : chunkLimit, hardLimit)
                let candidate = current.isEmpty ? piece : current + " " + piece
                if candidate.count <= limit {
                    current = candidate
                } else {
                    flush()
                    current = piece
                    // An oversized single sentence (> chunkLimit) goes alone.
                    if piece.count > chunkLimit { flush() }
                }
            }
        }
        flush()
        return result
    }

    /// Sentences beyond the hard limit split at the nearest clause punctuation before the boundary, else the nearest
    /// space, else a hard cut. Split pieces stay standalone chunks.
    private static let clausePunctuation: Set<Character> = [",", ";", ":", "—", "–"]

    static func splitOversized(_ sentence: String, hardLimit: Int = hardSplitLimit) -> [String] {
        guard sentence.count > hardLimit else { return [sentence] }
        var pieces: [String] = []
        var rest = Substring(sentence)
        while rest.count > hardLimit {
            let window = rest.prefix(hardLimit)
            var cut = window.endIndex
            if let punctuation = window.lastIndex(where: { clausePunctuation.contains($0) }) {
                cut = window.index(after: punctuation)
            } else if let space = window.lastIndex(where: { $0 == " " }) {
                cut = space
            }
            let piece = rest[rest.startIndex..<cut].trimmingCharacters(in: .whitespaces)
            if !piece.isEmpty { pieces.append(piece) }
            rest = rest[cut...].drop(while: { $0 == " " })
        }
        let tail = rest.trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty { pieces.append(tail) }
        return pieces
    }
}
