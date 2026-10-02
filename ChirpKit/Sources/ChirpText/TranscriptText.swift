// New for iChirp (plan 024 Task 8, review R2-1 / R4-1 / R1-3; the read seam of plan 025 "The shared accessor"). The
// one place that says which text of a transcript a consumer gets: the words as heard (the timed Transcript screen,
// subtitles) or the text the person sees (Copy, model input, Ask, Jev, the text exports). It stores nothing.

import ChirpCore
import Foundation

/// Which text a consumer needs.
public enum TranscriptTextView: Sendable, Hashable {
    /// The words as heard: what the timed Transcript screen shows (ADR-009), SRT/VTT and JSON segments.
    case heard
    /// What Copy, Share's text, model input (Transform, Ask, Create), Jev and the TXT/Markdown/PDF/Word exports use:
    /// the person's clean-up mode (`TranscriptTextBuilder.shownText(of:view:)` says which stored text that is).
    case shown(CleanupMode)
}

/// The clean-up rules a Clean view computed over the word stream needs (plan 025 R6). Unedited rows use the clean text
/// stored when the item was transcribed, so nothing here reads these rules yet; plan 025 Part A applies them to edited
/// streams. `.none` means no custom words or snippets.
public struct TranscriptTextContext: Sendable {
    /// Manual custom words only.
    public var customWords: [CustomWord]
    /// Used for dictation rows only, as the dictation pipeline does.
    public var snippets: [TextSnippet]
    public var removeUmFiller: Bool

    public init(customWords: [CustomWord] = [], snippets: [TextSnippet] = [], removeUmFiller: Bool = true) {
        self.customWords = customWords
        self.snippets = snippets
        self.removeUmFiller = removeUmFiller
    }

    public static let none = TranscriptTextContext()
}

/// One unit of the word stream: an engine word (plan 025 Part A adds edits that replace a run of them).
public struct TranscriptToken: Sendable, Equatable {
    public var text: String
    public var startMs: Int
    public var endMs: Int
    public var speakerId: String?
    /// Indexes into the engine's words; one word unless edited.
    public var wordRange: Range<Int>
    /// The correction that produced it; nil for an engine word.
    public var editID: UUID?

    public init(
        text: String, startMs: Int, endMs: Int, speakerId: String?, wordRange: Range<Int>, editID: UUID? = nil
    ) {
        self.text = text
        self.startMs = startMs
        self.endMs = endMs
        self.speakerId = speakerId
        self.wordRange = wordRange
        self.editID = editID
    }
}

/// One reading paragraph of a view. Boundaries come from the engine's words (`TranscriptParagraphBuilder`), so a
/// line's `id` is the same in every view and stays stable: it is the Transcript screen's paragraph index.
public struct TranscriptTextLine: Sendable, Equatable, Identifiable {
    /// The reading-paragraph index (0-based). A view may leave out a line that has no text (a Clean line that held
    /// only fillers), so ids can skip numbers; they never move.
    public var id: Int
    /// Nil without word timings.
    public var startMs: Int?
    public var endMs: Int?
    public var speakerId: String?
    /// The speaker's current name, only when the row has real speakers (a roster); nil otherwise, never
    /// "Unknown Speaker" (review R2-1).
    public var speakerLabel: String?
    public var text: String
    /// The engine's words this line spans; empty for untimed rows.
    public var wordRange: Range<Int>
    /// Into `TranscriptText.tokens`; empty for untimed rows.
    public var tokenRange: Range<Int>

    public init(
        id: Int, startMs: Int?, endMs: Int?, speakerId: String?, speakerLabel: String?, text: String,
        wordRange: Range<Int>, tokenRange: Range<Int>
    ) {
        self.id = id
        self.startMs = startMs
        self.endMs = endMs
        self.speakerId = speakerId
        self.speakerLabel = speakerLabel
        self.text = text
        self.wordRange = wordRange
        self.tokenRange = tokenRange
    }
}

/// A transcript as one view shows it.
public struct TranscriptText: Sendable, Equatable {
    public var view: TranscriptTextView
    /// The word stream every view is built from (`TranscriptTokens.of`).
    public var tokens: [TranscriptToken]
    /// The reading paragraphs, with times when the row has word timings; one untimed line of `plainText` otherwise.
    public var lines: [TranscriptTextLine]
    /// The whole text of this view (Copy, JSON `text`).
    public var plainText: String
    /// The row has a speaker roster: lines carry speaker names.
    public var hasSpeakers: Bool
    /// The row has word timings: lines carry times.
    public var hasWordTimings: Bool

    public init(
        view: TranscriptTextView, tokens: [TranscriptToken], lines: [TranscriptTextLine], plainText: String,
        hasSpeakers: Bool, hasWordTimings: Bool
    ) {
        self.view = view
        self.tokens = tokens
        self.lines = lines
        self.plainText = plainText
        self.hasSpeakers = hasSpeakers
        self.hasWordTimings = hasWordTimings
    }
}

/// R1: the one place the word stream is made. Today it maps the engine's words 1:1; plan 025 Part A applies the
/// person's corrections here, and nowhere else.
public enum TranscriptTokens {
    public static func of(_ transcription: Transcription) -> [TranscriptToken] {
        (transcription.wordTimestamps ?? []).enumerated().map { index, word in
            TranscriptToken(
                text: word.word, startMs: word.startMs, endMs: word.endMs, speakerId: word.speakerId,
                wordRange: index..<(index + 1))
        }
    }

    /// The stream as word timings (subtitles): an engine word keeps its confidence.
    public static func words(of transcription: Transcription) -> [WordTimestamp] {
        let engineWords = transcription.wordTimestamps ?? []
        return of(transcription).map { token in
            let confidence =
                token.editID == nil && token.wordRange.count == 1
                    && engineWords.indices.contains(token.wordRange.lowerBound)
                ? engineWords[token.wordRange.lowerBound].confidence : 1
            return WordTimestamp(
                word: token.text, startMs: token.startMs, endMs: token.endMs, confidence: confidence,
                speakerId: token.speakerId)
        }
    }
}

extension Transcription {
    /// The transcript as `view` shows it (`TranscriptTextView`).
    public func text(_ view: TranscriptTextView, context: TranscriptTextContext = .none) -> TranscriptText {
        TranscriptTextBuilder.build(self, view: view, context: context)
    }

    /// The whole text of `view`, without building lines (Library search, titles; plan 025 R3). Equal to
    /// `text(view, context:).plainText`.
    public func plainText(_ view: TranscriptTextView, context: TranscriptTextContext = .none) -> String {
        TranscriptTextBuilder.plainText(self, view: view)
    }
}

/// Builds `TranscriptText`. Internal: consumers go through `Transcription.text(_:context:)`.
enum TranscriptTextBuilder {
    /// The stored text a view shows when the row is read as a whole:
    /// - `.heard`: the clean text when there is one, else the raw text (what the Transcript screen shows for an
    ///   untimed row); timed rows show their words instead.
    /// - `.shown(.raw)`: the raw transcript (clean only when raw is missing), except a dictation whose final pass
    ///   stored polished text: the person chose Polish after (or Clean) for it and its Done screen copied that text, so
    ///   that is its text in either mode (review R4-1).
    /// - `.shown(.clean)`: the clean transcript when it is not blank, else the raw one.
    static func shownText(of transcription: Transcription, view: TranscriptTextView) -> String {
        switch view {
        case .heard, .shown(.clean):
            return transcription.displayText
        case .shown(.raw):
            if transcription.sourceType == .dictation, hasCleanText(transcription) {
                return transcription.displayText
            }
            return transcription.rawTranscript ?? transcription.cleanTranscript ?? ""
        }
    }

    static func plainText(_ transcription: Transcription, view: TranscriptTextView) -> String {
        shownText(of: transcription, view: view)
    }

    private static func hasCleanText(_ transcription: Transcription) -> Bool {
        guard let clean = transcription.cleanTranscript else { return false }
        return !clean.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// True when the view's text is the stored clean text rather than the words: its lines then carry that text,
    /// placed on the word lines it came from (`CleanTextAligner`).
    private static func showsCleanText(_ transcription: Transcription, view: TranscriptTextView) -> Bool {
        guard hasCleanText(transcription) else { return false }
        switch view {
        case .heard: return false
        case .shown(.clean): return true
        case .shown(.raw): return transcription.sourceType == .dictation
        }
    }

    static func build(_ transcription: Transcription, view: TranscriptTextView, context: TranscriptTextContext)
        -> TranscriptText
    {
        let tokens = TranscriptTokens.of(transcription)
        let roster = transcription.speakers ?? []
        let hasSpeakers = !roster.isEmpty
        let plain = plainText(transcription, view: view)
        guard !tokens.isEmpty else {
            let lines =
                plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? []
                : [
                    TranscriptTextLine(
                        id: 0, startMs: nil, endMs: nil, speakerId: nil, speakerLabel: nil, text: plain,
                        wordRange: 0..<0, tokenRange: 0..<0)
                ]
            return TranscriptText(
                view: view, tokens: [], lines: lines, plainText: plain, hasSpeakers: hasSpeakers,
                hasWordTimings: false)
        }

        let labels = Dictionary(roster.map { ($0.id, $0.label) }, uniquingKeysWith: { first, _ in first })
        let words = tokens.map {
            WordTimestamp(word: $0.text, startMs: $0.startMs, endMs: $0.endMs, confidence: 1, speakerId: $0.speakerId)
        }
        var lines = TranscriptParagraphBuilder.buildWithWordRanges(from: words).enumerated().map { index, built in
            let speakerId = built.paragraph.speakerId
            return TranscriptTextLine(
                id: index, startMs: built.paragraph.startMs, endMs: built.paragraph.endMs, speakerId: speakerId,
                speakerLabel: hasSpeakers ? speakerId.map { labels[$0] ?? $0 } : nil, text: built.paragraph.text,
                // No edits yet (plan 025 Part A): token i is engine word i.
                wordRange: built.wordRange, tokenRange: built.wordRange)
        }
        if showsCleanText(transcription, view: view) {
            lines = CleanTextAligner.place(plain, on: lines, tokens: tokens)
        }
        return TranscriptText(
            view: view, tokens: tokens, lines: lines, plainText: plain, hasSpeakers: hasSpeakers, hasWordTimings: true)
    }
}

/// Puts a stored clean text on the word lines it came from, so a Clean view keeps the lines' times and speakers
/// (model input with timestamps, exports with turns) while every word it shows is the clean text's. Clean-up only
/// drops fillers, swaps custom words, expands snippets and tidies spaces and case, so most clean words match a
/// heard word: a word diff (`CollectionDifference`, case and edge punctuation ignored) anchors them. Between two
/// anchors, the clean words that replaced heard ones go with the line of the words they replaced; when those span a
/// paragraph break that follows a sentence end, the clean words move to the next line after their own sentence end
/// (a snippet's expansion stays with its trigger's paragraph). Added words with nothing replaced go with the line
/// before them. Nothing is dropped: the lines, read in order, hold every word of the clean text, separated by single
/// spaces.
enum CleanTextAligner {
    static func place(_ clean: String, on lines: [TranscriptTextLine], tokens: [TranscriptToken])
        -> [TranscriptTextLine]
    {
        guard !lines.isEmpty else { return lines }
        // The heard side: every whitespace-separated piece of every token, with the line it sits on.
        var heard: [String] = []
        var heardLine: [Int] = []
        var heardEndsSentence: [Bool] = []
        for (position, line) in lines.enumerated() {
            for token in tokens[line.tokenRange] {
                for piece in token.text.split(whereSeparator: \.isWhitespace) {
                    heard.append(normalized(piece))
                    heardLine.append(position)
                    heardEndsSentence.append(endsSentence(piece))
                }
            }
        }
        let shownPieces = clean.split(whereSeparator: \.isWhitespace).map(String.init)
        let shown = shownPieces.map { normalized(Substring($0)) }
        var removed = Set<Int>()
        var inserted = Set<Int>()
        for change in shown.difference(from: heard) {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }

        var placement = [Int](repeating: 0, count: shown.count)
        var heardIndex = 0
        var shownIndex = 0
        var lastLine: Int?
        var waitingForAnchor: [Int] = []
        while heardIndex < heard.count || shownIndex < shown.count {
            // One run of changes between anchors: the heard words it removed and the clean words it added.
            var removedRun: [Int] = []
            var insertedRun: [Int] = []
            while true {
                if heardIndex < heard.count, removed.contains(heardIndex) {
                    removedRun.append(heardIndex)
                    heardIndex += 1
                } else if shownIndex < shown.count, inserted.contains(shownIndex) {
                    insertedRun.append(shownIndex)
                    shownIndex += 1
                } else {
                    break
                }
            }
            if removedRun.isEmpty {
                if let lastLine {
                    for index in insertedRun { placement[index] = lastLine }
                } else {
                    waitingForAnchor += insertedRun
                }
            } else {
                // The replaced words' lines, in order, each with whether its last replaced word ends a sentence.
                var groups: [(line: Int, endsSentence: Bool)] = []
                for index in removedRun {
                    if groups.last?.line == heardLine[index] {
                        groups[groups.count - 1].endsSentence = heardEndsSentence[index]
                    } else {
                        groups.append((heardLine[index], heardEndsSentence[index]))
                    }
                }
                var group = 0
                for index in insertedRun {
                    placement[index] = groups[group].line
                    if group < groups.count - 1, groups[group].endsSentence, endsSentence(Substring(shownPieces[index]))
                    {
                        group += 1
                    }
                }
            }
            guard heardIndex < heard.count, shownIndex < shown.count else { break }
            // An anchor: the same word on both sides.
            let line = heardLine[heardIndex]
            placement[shownIndex] = line
            for index in waitingForAnchor { placement[index] = line }
            waitingForAnchor.removeAll()
            lastLine = line
            heardIndex += 1
            shownIndex += 1
        }
        for index in waitingForAnchor { placement[index] = lastLine ?? 0 }

        var texts = [[String]](repeating: [], count: lines.count)
        for (index, piece) in shownPieces.enumerated() {
            texts[placement[index]].append(piece)
        }
        return lines.enumerated().compactMap { position, line in
            guard !texts[position].isEmpty else { return nil }
            var placed = line
            placed.text = texts[position].joined(separator: " ")
            return placed
        }
    }

    /// Lowercased, without punctuation at either end ("Um," and "um" match); a piece of punctuation only stays as is.
    private static func normalized(_ piece: Substring) -> String {
        let trimmed = piece.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        return (trimmed.isEmpty ? String(piece) : trimmed).lowercased()
    }

    /// Ends with ".", "!", "?" or "…", before any closing quote or bracket.
    private static func endsSentence(_ piece: Substring) -> Bool {
        let closers: Set<Character> = ["\"", "'", ")", "]", "”", "’", "»"]
        guard let last = piece.reversed().first(where: { !closers.contains($0) }) else { return false }
        return ".!?…".contains(last)
    }
}
