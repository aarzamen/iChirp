import ChirpCore
import ChirpText
import Foundation

/// The only text a decision may send: at most `limit` characters of the transcript, cut back to a sentence boundary,
/// plus a few content-free facts. Nothing else from the transcript leaves the phone (spec/12).
public enum DecisionInputWindow {
    /// Deliberate: cost, latency, and the least text that can leave the phone. Widen only with an eval that shows it
    /// matters (plan 021, maintenance notes).
    public static let limit = 3_000
    /// Paragraph tagging looks at no more than this many paragraphs.
    public static let maximumTaggedParagraphs = 12

    private static let sentenceEnds: Set<Character> = [".", "!", "?", "…", "。", "！", "？"]
    private static let closers: Set<Character> = ["\"", "'", "”", "’", ")", "]", "»"]

    /// The first `limit` characters of `text`, trimmed, cut back to the last sentence end (a `.`, `!`, `?` or `…`,
    /// with any closing quote, followed by a space or the end of the text). When the only sentence end is in the first
    /// third of the window, it cuts at the last space instead, so one long unpunctuated sentence still gives the model
    /// something to read. Text within the limit is returned whole.
    public static func excerpt(_ text: String, limit: Int = limit) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard limit > 0 else { return "" }
        guard trimmed.count > limit else { return trimmed }
        let characters = Array(trimmed)
        // A sentence end counts when the character after it (in the whole text) is whitespace.
        var lastSentenceEnd: Int?
        var index = 0
        while index < limit {
            if sentenceEnds.contains(characters[index]) {
                var end = index
                while end + 1 < limit, closers.contains(characters[end + 1]) { end += 1 }
                let next = end + 1
                if next < characters.count, characters[next].isWhitespace { lastSentenceEnd = end }
                index = end
            }
            index += 1
        }
        if let end = lastSentenceEnd, end + 1 >= limit / 3 {
            return String(characters[0...end])
        }
        if let space = (0..<limit).last(where: { characters[$0].isWhitespace && $0 > 0 }) {
            return String(characters[0..<space]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return String(characters[0..<limit])
    }

    /// The paragraphs the Transcript screen shows (the same rule as `TranscriptViewModel`): built from the words when
    /// there are timings, else one paragraph of `displayText`.
    public static func paragraphs(of transcription: Transcription) -> [TranscriptParagraph] {
        if let words = transcription.wordTimestamps, !words.isEmpty {
            return TranscriptParagraphBuilder.build(from: words)
        }
        let text = transcription.displayText
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        return [TranscriptParagraph(startMs: 0, endMs: transcription.durationMs ?? 0, text: text, speakerId: nil)]
    }

    /// Content-free facts: duration, speaker count, paragraph count and the kind of source. Never names or titles.
    public static func facts(for transcription: Transcription, paragraphCount: Int) -> [String: String] {
        [
            "duration_seconds": transcription.durationMs.map { String($0 / 1000) } ?? "unknown",
            "speaker_count": transcription.speakerCount.map(String.init) ?? "unknown",
            "paragraph_count": String(paragraphCount),
            "source": source(of: transcription),
        ]
    }

    /// `audio` (a file, dictation or meeting), `document` or `link` (a web, podcast or YouTube link).
    public static func source(of transcription: Transcription) -> String {
        switch transcription.sourceType {
        case .file, .dictation, .meeting: "audio"
        // Plan 022: typed or pasted text is sent to Jev under the same label as a document (the contract's values).
        case .document, .text: "document"
        case .url, .podcast: "link"
        }
    }

    /// The paragraph id a tag question uses: `p01` … `p12`.
    public static func paragraphID(_ index: Int) -> String {
        String(format: "p%02d", index + 1)
    }

    /// The paragraph-tagging state text: the first paragraphs (at most 12), each on its own line after its id
    /// (`p01: …`), stopping before one that would cross `limit`. A first paragraph longer than the window is cut like
    /// `excerpt`. Returns the text and the indexes of the paragraphs it holds.
    public static func paragraphExcerpt(_ paragraphs: [TranscriptParagraph], limit: Int = limit) -> (
        text: String, indexes: [Int]
    ) {
        var text = ""
        var indexes: [Int] = []
        for (index, paragraph) in paragraphs.prefix(maximumTaggedParagraphs).enumerated() {
            let body = paragraph.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { continue }
            let separator = text.isEmpty ? "" : "\n\n"
            let prefix = "\(paragraphID(index)): "
            let entry = separator + prefix + body
            if text.count + entry.count <= limit {
                text += entry
                indexes.append(index)
                continue
            }
            if indexes.isEmpty {
                let room = limit - prefix.count
                let cut = excerpt(body, limit: room)
                if !cut.isEmpty {
                    text = prefix + cut
                    indexes.append(index)
                }
            }
            break
        }
        return (text, indexes)
    }
}
