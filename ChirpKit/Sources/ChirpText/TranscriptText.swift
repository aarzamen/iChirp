// New for iChirp (plan 024 Task 8, review R2-1 / R4-1 / R1-3; the read seam of plan 025 "The shared accessor"). The
// one place that says which text of a transcript a consumer gets: the words as heard (the timed Transcript screen,
// subtitles) or the text the person sees (Copy, model input, Ask, Jev, the text exports). It stores nothing.
// Plan 025 Part A: the person's corrections (`Transcription.textCorrections`) enter the word stream here, in
// `TranscriptTokens.of`, and nowhere else (semantics from MacParakeet ADR-031: one effective projection every
// consumer uses; edited text keeps only the time envelope of the words it replaced).

import ChirpCore
import Foundation

/// Which text a consumer needs.
public enum TranscriptTextView: Sendable, Hashable {
    /// The words as heard (plus the person's corrections): what the timed Transcript screen shows (ADR-009), SRT/VTT
    /// and JSON segments.
    case heard
    /// What Copy, Share's text, model input (Transform, Ask, Create), Jev and the TXT/Markdown/PDF/Word exports use:
    /// the person's clean-up mode (`TranscriptTextBuilder.shownText(of:view:)` says which stored text that is).
    case shown(CleanupMode)
}

/// The clean-up rules a Clean view computed over the word stream needs (plan 025 R6). Unedited rows use the clean text
/// stored when the item was transcribed and read none of these; a row with corrections runs the deterministic
/// clean-up over its corrected stream with them (R4). The app builds it from Settings
/// (`TranscriptTextContext.current(textRules:settings:)` in ChirpFeatures). `.none` means no custom words or snippets
/// and the default filler rule.
public struct TranscriptTextContext: Sendable {
    /// Manual, enabled custom words only (learned rules act only as corrections, plan 025 D8).
    public var customWords: [CustomWord]
    /// Enabled snippets; used for dictation rows only, as the dictation pipeline does.
    public var snippets: [TextSnippet]
    /// The person's "remove um" setting (`TranscriptionSettings.removeUmFiller`).
    public var removeUmFiller: Bool

    public init(customWords: [CustomWord] = [], snippets: [TextSnippet] = [], removeUmFiller: Bool = true) {
        self.customWords = customWords
        self.snippets = snippets
        self.removeUmFiller = removeUmFiller
    }

    public static let none = TranscriptTextContext()
}

/// One unit of the word stream: an engine word, or one correction that replaced a run of them.
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
/// line's `id` is the same in every view and stays stable, corrected or not: it is the Transcript screen's paragraph
/// index.
public struct TranscriptTextLine: Sendable, Equatable, Identifiable {
    /// The reading-paragraph index (0-based). A view may leave out a line that has no text (a Clean line that held
    /// only fillers, or a line whose words a correction that starts on an earlier line covers), so ids can skip
    /// numbers; they never move.
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
    /// Into `TranscriptText.tokens`: the tokens that start in `wordRange`. Empty for untimed rows.
    public var tokenRange: Range<Int>
    /// Plan 025: where each token of `tokenRange` sits in `text` (UTF-16 offsets), for the correction marks. Empty when
    /// `text` is not the tokens joined (a Clean line carries the clean text) and for untimed rows.
    public var tokenUTF16Ranges: [Range<Int>]

    public init(
        id: Int, startMs: Int?, endMs: Int?, speakerId: String?, speakerLabel: String?, text: String,
        wordRange: Range<Int>, tokenRange: Range<Int>, tokenUTF16Ranges: [Range<Int>] = []
    ) {
        self.id = id
        self.startMs = startMs
        self.endMs = endMs
        self.speakerId = speakerId
        self.speakerLabel = speakerLabel
        self.text = text
        self.wordRange = wordRange
        self.tokenRange = tokenRange
        self.tokenUTF16Ranges = tokenUTF16Ranges
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
    /// Plan 025: the stream as word timings (subtitles, Extract fields): an engine word keeps its own time and
    /// confidence; a correction is one word with the envelope of the words it replaced, confidence 1, line breaks
    /// flattened to spaces. Empty without word timings.
    public var words: [WordTimestamp]
    /// Plan 025: the row's stored segments; with corrections, stored segments a correction straddles merge into one
    /// (the first's id, start and speaker, the last's end, the union of their word ranges), and a segment that holds a
    /// correction carries the corrected text and `isTextEdited`. Its `wordRange` still indexes the engine's words.
    public var segments: [TranscriptSegmentRecord]?
    /// Plan 025: the corrections applied, in order (empty on the fast path).
    public var edits: [TranscriptCorrection]

    public init(
        view: TranscriptTextView, tokens: [TranscriptToken], lines: [TranscriptTextLine], plainText: String,
        hasSpeakers: Bool, hasWordTimings: Bool, words: [WordTimestamp] = [],
        segments: [TranscriptSegmentRecord]? = nil, edits: [TranscriptCorrection] = []
    ) {
        self.view = view
        self.tokens = tokens
        self.lines = lines
        self.plainText = plainText
        self.hasSpeakers = hasSpeakers
        self.hasWordTimings = hasWordTimings
        self.words = words
        self.segments = segments
        self.edits = edits
    }

    /// Plan 025: the words as heard of the engine-word range `range`, from this view's own tokens (an engine token's
    /// text, a correction token's `heard`), for a range of whole tokens (`CorrectionPlanner`): each word trimmed,
    /// joined by single spaces, as `TranscriptCorrection.heard` and `Transcription.heardText(_:)` are.
    public func heardText(_ range: Range<Int>) -> String {
        tokens.filter { $0.wordRange.overlaps(range) }
            .map { token in
                guard let editID = token.editID, let edit = edits.first(where: { $0.id == editID }) else {
                    return token.text.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                return edit.heard
            }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

/// R1: the one place the word stream is made: the engine's words, with each valid correction
/// (`TranscriptCorrections.validItems(in:)`) replacing its run of words by one token. Nothing else applies corrections.
public enum TranscriptTokens {
    public static func of(_ transcription: Transcription) -> [TranscriptToken] {
        tokens(words: transcription.wordTimestamps ?? [], edits: edits(of: transcription))
    }

    /// The corrections the stream applies: the valid items, in order. None for a row without word timings, a newer
    /// build's envelope or detached items.
    public static func edits(of transcription: Transcription) -> [TranscriptCorrection] {
        guard let corrections = transcription.textCorrections, !corrections.items.isEmpty,
            let words = transcription.wordTimestamps, !words.isEmpty
        else { return [] }
        return corrections.validItems(in: words)
    }

    /// The stream as word timings (subtitles): an engine word keeps its confidence; a correction has confidence 1 and
    /// its line breaks flattened to spaces (a cue or a word never holds one).
    public static func words(of transcription: Transcription) -> [WordTimestamp] {
        words(of: of(transcription), engine: transcription.wordTimestamps ?? [])
    }

    static func tokens(words: [WordTimestamp], edits: [TranscriptCorrection]) -> [TranscriptToken] {
        var tokens: [TranscriptToken] = []
        tokens.reserveCapacity(words.count)
        var index = 0
        func appendWords(upTo end: Int) {
            while index < end {
                let word = words[index]
                tokens.append(
                    TranscriptToken(
                        text: word.word, startMs: word.startMs, endMs: word.endMs, speakerId: word.speakerId,
                        wordRange: index..<(index + 1)))
                index += 1
            }
        }
        for edit in edits {
            let range = edit.range
            appendWords(upTo: range.lowerBound)
            tokens.append(
                TranscriptToken(
                    text: edit.text, startMs: words[range.lowerBound].startMs, endMs: words[range.upperBound - 1].endMs,
                    speakerId: words[range.lowerBound].speakerId, wordRange: range, editID: edit.id))
            index = range.upperBound
        }
        appendWords(upTo: words.count)
        return tokens
    }

    static func words(of tokens: [TranscriptToken], engine: [WordTimestamp]) -> [WordTimestamp] {
        tokens.map { token in
            guard
                token.editID != nil || token.wordRange.count != 1
                    || !engine.indices.contains(token.wordRange.lowerBound)
            else { return engine[token.wordRange.lowerBound] }
            return WordTimestamp(
                word: token.text.split(whereSeparator: \.isWhitespace).joined(separator: " "),
                startMs: token.startMs, endMs: token.endMs, confidence: 1, speakerId: token.speakerId)
        }
    }
}

extension Transcription {
    /// The transcript as `view` shows it (`TranscriptTextView`).
    public func text(_ view: TranscriptTextView, context: TranscriptTextContext = .none) -> TranscriptText {
        TranscriptTextBuilder.build(self, view: view, context: context)
    }

    /// The whole text of `view`, without building lines (Library search, titles; plan 025 R3). Equal to
    /// `text(view, context:).plainText`. A row without corrections returns its stored text at once.
    public func plainText(_ view: TranscriptTextView, context: TranscriptTextContext = .none) -> String {
        TranscriptTextBuilder.plainText(self, view: view, context: context)
    }

    /// Plan 025: the fingerprint of the engine's words (`TranscriptFingerprint`). A screen keeps the one it loaded; a
    /// correction write is refused when the stored words no longer have it.
    public var wordsFingerprint: String {
        TranscriptFingerprint.of(wordTimestamps ?? [])
    }

    /// Plan 025: the row has engine word timings, which corrections need (D1).
    public var hasWordTimings: Bool {
        wordTimestamps?.isEmpty == false
    }

    /// Plan 025: applies `plan` to `textCorrections` against the engine's words (`TranscriptCorrections.applying`) and
    /// returns its inverse. Only `TranscriptCorrectionService` calls it, inside the store's one-row transaction.
    public mutating func applyCorrections(_ plan: TranscriptCorrectionPlan, now: Date) throws
        -> TranscriptCorrectionPlan
    {
        let (corrections, inverse) = try (textCorrections ?? .empty).applying(
            plan, words: wordTimestamps ?? [], now: now)
        textCorrections = corrections
        return inverse
    }

    /// Plan 025: the text a derived title and snippet come from. Without corrections it is the pipelines' own source
    /// (the clean text when there is one, else the raw), so reverting every correction restores their title exactly;
    /// with corrections it is the corrected text in the row's own mode (`.shown(.clean)` when it has clean text, else
    /// `.shown(.raw)`).
    public func titleSource(context: TranscriptTextContext) -> String? {
        guard !TranscriptTokens.edits(of: self).isEmpty else { return cleanTranscript ?? rawTranscript }
        return plainText(.shown(cleanTranscript == nil ? .raw : .clean), context: context)
    }

    /// The engine's words of `wordRange` as heard (each trimmed, joined by single spaces): Show Original, and what a
    /// correction's `heard` holds. Empty outside the words.
    public func heardText(_ wordRange: Range<Int>) -> String {
        let words = wordTimestamps ?? []
        let range = wordRange.clamped(to: 0..<words.count)
        return TranscriptCorrections.heardText(of: words, in: range)
    }
}

/// Builds `TranscriptText`. Internal: consumers go through `Transcription.text(_:context:)`.
enum TranscriptTextBuilder {
    /// The stored text a view shows when the row is read as a whole (the fast path, a row without corrections):
    /// - `.heard`: a timed row's engine text (the raw transcript; the clean one only when raw is missing), the words
    ///   its lines show; an untimed row's clean text when there is one, else its raw text (what the Transcript screen
    ///   shows for it).
    /// - `.shown(.raw)`: the raw transcript (clean only when raw is missing), except a dictation whose final pass
    ///   stored polished text: the person chose Polish after (or Clean) for it and its Done screen copied that text, so
    ///   that is its text in either mode (review R4-1).
    /// - `.shown(.clean)`: the clean transcript when it is not blank, else the raw one.
    static func shownText(of transcription: Transcription, view: TranscriptTextView) -> String {
        let rawFirst = transcription.rawTranscript ?? transcription.cleanTranscript ?? ""
        switch view {
        case .heard:
            return transcription.wordTimestamps?.isEmpty == false ? rawFirst : transcription.displayText
        case .shown(.clean):
            return transcription.displayText
        case .shown(.raw):
            if transcription.sourceType == .dictation, hasCleanText(transcription) {
                return transcription.displayText
            }
            return rawFirst
        }
    }

    static func plainText(_ transcription: Transcription, view: TranscriptTextView, context: TranscriptTextContext)
        -> String
    {
        let edits = TranscriptTokens.edits(of: transcription)
        guard !edits.isEmpty, let words = transcription.wordTimestamps else {
            return shownText(of: transcription, view: view)
        }
        return editedText(
            transcription, view: view, context: context, tokens: TranscriptTokens.tokens(words: words, edits: edits))
    }

    /// The whole text of a corrected stream (plan 025 D2): the tokens joined with upstream's separators
    /// (`FileTranscriptSegments.joinedText`); where the view would show the stored clean text, the deterministic
    /// clean-up over that joined text with the context's rules instead (R4: the stored clean text has no word mapping).
    /// A row that never had clean text gets no fresh clean-up, as it had none before its first correction.
    private static func editedText(
        _ transcription: Transcription, view: TranscriptTextView, context: TranscriptTextContext,
        tokens: [TranscriptToken]
    ) -> String {
        let joined = FileTranscriptSegments.joinedText(tokens.map(\.text))
        guard showsCleanText(transcription, view: view) else { return joined }
        return TextProcessingPipeline().process(
            text: joined, customWords: context.customWords,
            snippets: transcription.sourceType == .dictation ? context.snippets : [],
            removeUmFiller: context.removeUmFiller
        ).text
    }

    private static func hasCleanText(_ transcription: Transcription) -> Bool {
        guard let clean = transcription.cleanTranscript else { return false }
        return !clean.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// True when the view's text is the clean text rather than the words: its lines then carry that text, placed on
    /// the word lines it came from (`CleanTextAligner`).
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
        let words = transcription.wordTimestamps ?? []
        let edits = TranscriptTokens.edits(of: transcription)
        let tokens = TranscriptTokens.tokens(words: words, edits: edits)
        let roster = transcription.speakers ?? []
        let hasSpeakers = !roster.isEmpty
        let plain =
            edits.isEmpty
            ? shownText(of: transcription, view: view)
            : editedText(transcription, view: view, context: context, tokens: tokens)
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
                hasWordTimings: false, segments: transcription.transcriptSegments)
        }

        let labels = Dictionary(roster.map { ($0.id, $0.label) }, uniquingKeysWith: { first, _ in first })
        var lines = heardLines(
            words: words, tokens: tokens,
            label: { speakerId in
                hasSpeakers ? speakerId.map { labels[$0] ?? $0 } : nil
            })
        if showsCleanText(transcription, view: view) {
            lines = CleanTextAligner.place(plain, on: lines, tokens: tokens)
        }
        return TranscriptText(
            view: view, tokens: tokens, lines: lines, plainText: plain, hasSpeakers: hasSpeakers, hasWordTimings: true,
            words: TranscriptTokens.words(of: tokens, engine: words),
            segments: edits.isEmpty
                ? transcription.transcriptSegments
                : correctedSegments(transcription.transcriptSegments, tokens: tokens, edits: edits),
            edits: edits)
    }

    /// The reading paragraphs of the engine's words (stable boundaries, R2), each holding the tokens that start in it,
    /// joined by single spaces, with where each token sits. A paragraph left with no token (a correction from an
    /// earlier line covers all its words) is left out.
    private static func heardLines(
        words: [WordTimestamp], tokens: [TranscriptToken], label: (String?) -> String?
    ) -> [TranscriptTextLine] {
        var lines: [TranscriptTextLine] = []
        var next = 0
        for (index, built) in TranscriptParagraphBuilder.buildWithWordRanges(from: words).enumerated() {
            let first = next
            while next < tokens.count, built.wordRange.contains(tokens[next].wordRange.lowerBound) {
                next += 1
            }
            guard next > first else { continue }
            var text = ""
            var ranges: [Range<Int>] = []
            ranges.reserveCapacity(next - first)
            for token in tokens[first..<next] {
                if !text.isEmpty { text += " " }
                let start = text.utf16.count
                text += token.text
                ranges.append(start..<text.utf16.count)
            }
            let paragraph = built.paragraph
            lines.append(
                TranscriptTextLine(
                    id: index, startMs: paragraph.startMs, endMs: paragraph.endMs, speakerId: paragraph.speakerId,
                    speakerLabel: label(paragraph.speakerId), text: text, wordRange: built.wordRange,
                    tokenRange: first..<next, tokenUTF16Ranges: ranges))
        }
        return lines
    }

    /// The stored segments with corrections applied (see `TranscriptText.segments`).
    private static func correctedSegments(
        _ stored: [TranscriptSegmentRecord]?, tokens: [TranscriptToken], edits: [TranscriptCorrection]
    ) -> [TranscriptSegmentRecord]? {
        guard let stored else { return nil }
        func range(_ segment: TranscriptSegmentRecord) -> Range<Int> {
            segment.wordRange.startIndex..<max(segment.wordRange.startIndex, segment.wordRange.endIndexExclusive)
        }
        var result: [TranscriptSegmentRecord] = []
        var first = 0
        while first < stored.count {
            var last = first
            while last + 1 < stored.count,
                edits.contains(where: {
                    $0.range.overlaps(range(stored[last])) && $0.range.overlaps(range(stored[last + 1]))
                })
            {
                last += 1
            }
            let union = range(stored[first]).lowerBound..<range(stored[last]).upperBound
            if edits.contains(where: { $0.range.overlaps(union) }) {
                var merged = stored[first]
                merged.endMs = stored[last].endMs
                merged.wordRange = TranscriptSegmentWordRange(
                    startIndex: union.lowerBound, endIndexExclusive: union.upperBound)
                merged.text = FileTranscriptSegments.joinedText(
                    tokens.filter { union.contains($0.wordRange.lowerBound) }.map(\.text))
                merged.isTextEdited = true
                result.append(merged)
            } else {
                result.append(contentsOf: stored[first...last])
            }
            first = last + 1
        }
        return result
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
            placed.tokenUTF16Ranges = []
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
