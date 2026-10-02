// UX audit F23 / plan 023. The inline half of the Markdown pipeline: bold, italic, inline code and links inside one
// block's text, shared by `MarkdownDocument` (keeps the emphasis, for display), `PlainTextFlattener` (drops the
// markup, keeps the words, for Copy) and `ChirpExport.ExportDocument.text` (the PDF and Word exports).
// Plan 024 Task 4 (review R2-8): a delimiter written between two Latin letters or digits ("25~50", "2**10", "x*2")
// is the person's character, never emphasis; `~` is never strikethrough; inline code is never escaped.

import Foundation

/// Resolves inline Markdown within a single block's text (never spans blocks — a block boundary is already decided
/// by `MarkdownBlockParser` — and never spans a line: each line is resolved on its own, so the screen, Copy and the
/// PDF/Word exports always show the same characters).
public enum MarkdownInline {
    /// `AttributedString(markdown:)`'s `.inlineOnlyPreservingWhitespace` syntax parses bold/italic/code spans and
    /// keeps whitespace literal (it never reflows a line or invents a new block) — exactly what a heading,
    /// paragraph line or list item's text needs. It also leaves anything it cannot parse as syntax exactly as
    /// written: an unpaired "*" ("50 * 2" is math, not italics), an unmatched "**" ("bold without close"), a
    /// "[bracket]" with no following "(url)" — verified in `MarkdownInlineTests`.
    ///
    /// What it does decode, deliberately (known item K3, plan 024 ruling): an HTML entity reference such as
    /// `&lt;`, `&amp;` or `&#8805;` becomes the character it names (`<`, `&`, `≥`), as CommonMark requires. The
    /// screen, Copy and the PDF/Word exports all go through this one function, so all of them show that same
    /// character (`MarkdownInlineTests.testHTMLEntitiesAreDecodedLikeTheScreenShowsThem`).
    private static let options = AttributedString.MarkdownParsingOptions(
        interpretedSyntax: .inlineOnlyPreservingWhitespace)

    /// The text with its Markdown emphasis resolved to attributes, for `Text(_:)` in `MarkdownDocument`.
    static func attributed(_ text: String) -> AttributedString {
        var result = AttributedString()
        for (index, line) in text.components(separatedBy: "\n").enumerated() {
            if index > 0 { result.append(AttributedString("\n")) }
            result.append(attributedLine(line))
        }
        return result
    }

    /// The same text with the Markdown syntax gone and every word kept: what Copy writes (`PlainTextFlattener`)
    /// and what the PDF and Word exports print (`ChirpExport.ExportDocument.text`).
    public static func plain(_ text: String) -> String {
        String(attributed(text).characters)
    }

    private static func attributedLine(_ line: String) -> AttributedString {
        let prepared = protectLiterals(neutralizeLinks(Array(line)))
        // The parser has never been seen to fail on inline-only input; if it does, show the line exactly as written.
        return (try? AttributedString(markdown: prepared, options: options)) ?? AttributedString(line)
    }

    // MARK: - Links

    /// Markdown link syntax renders as just the label — `AttributedString` turns "[Google](url)" into "Google" and
    /// drops "url" entirely. That would silently lose text on Copy (the owner's "no text is lost" rule, F23), so a
    /// link is rewritten to "label (url)" before parsing; `MarkdownDocument`, `PlainTextFlattener` and the PDF/Word
    /// exports all see the same rewritten text; the app does not otherwise use Markdown links so nothing "goes
    /// plain-text" that used to be tappable. A link inside inline code or an autolink, or one whose "[" the source
    /// escaped, is not a link and stays exactly as written. A bare URL in a link's label or address does not stop
    /// the rewrite: Foundation lets the link win there and would drop the address (measured:
    /// "[https://a.com](https://b.com)" showed only "https://a.com").
    private static func neutralizeLinks(_ chars: [Character]) -> [Character] {
        guard chars.contains("]") else { return chars }
        let verbatim = verbatimSpans(in: chars, bareLinks: false)
        func isVerbatim(_ index: Int) -> Bool { verbatim.contains { $0.contains(index) } }
        var result: [Character] = []
        result.reserveCapacity(chars.count + 4)
        var index = 0
        while index < chars.count {
            if let span = verbatim.first(where: { $0.lowerBound == index }) {
                result.append(contentsOf: chars[span])
                index = span.upperBound
                continue
            }
            if chars[index] == "\\", index + 1 < chars.count, isASCIIPunctuation(chars[index + 1]) {
                result.append(contentsOf: chars[index...(index + 1)])
                index += 2
                continue
            }
            // "[label](url)": the label runs to the first "]", the address to the first ")" (the rule the earlier
            // regular expression used), and none of its delimiters may sit inside inline code or an autolink.
            if chars[index] == "[",
                let close = chars[(index + 1)...].firstIndex(of: "]"),
                close + 1 < chars.count, chars[close + 1] == "(",
                let end = chars[(close + 2)...].firstIndex(of: ")"),
                ![close, close + 1, end].contains(where: isVerbatim)
            {
                result.append(contentsOf: chars[(index + 1)..<close])
                result.append(contentsOf: " (")
                result.append(contentsOf: chars[(close + 2)..<end])
                result.append(")")
                index = end + 1
                continue
            }
            result.append(chars[index])
            index += 1
        }
        return result
    }

    // MARK: - Delimiters that are the person's characters

    /// Escapes, with CommonMark's own backslash, every delimiter that is the person's character rather than
    /// Markdown, so the parser keeps it literal:
    ///
    /// - A run of `*` written between two Latin letters or digits ("2*3", "2**10", "x*2", "Q6H*PRN"). CommonMark lets
    ///   such a run open *and* close emphasis, so two of them on one line paired with each other across the words
    ///   between them and dropped both — "2*3 tablets, 2*3 more" lost its asterisks, "2**10 and 3**4" became
    ///   "210 and 34" (`PlainTextFlattenerPropertyTests` caught the first). Real emphasis is written next to a space
    ///   or the line's edge ("**Plan:**", "*twice daily*") and is unaffected; CJK text, where emphasis is written
    ///   with no spaces, keeps CommonMark's reading.
    /// - Every `~` (ruling, plan 024 Task 4, review R2-8). Foundation reads GitHub's strikethrough with one or two
    ///   tildes, so "metoprolol 25~50 mg q8~12h" struck "50 mg q8" through and Copy gave "2550 mg q812h". In
    ///   clinical writing `~` means "about" or a range, and struck text that Copy turns into plain text would read
    ///   as live text, so this app never strikes text through: `~~text~~` shows and copies with its tildes.
    /// - Every backtick that does not open or close inline code (a backtick between two digits, "5`10", is the
    ///   person's character, not a code span pairing across the words to the next one).
    /// - The `*` or `_` runs the parser would pair around content with no letter or digit: that is never emphasis
    ///   around words but a form's blanks or the person's symbols — "BP: ___/___ mmHg" copied as "BP: / mmHg" and
    ///   "Date: __/__/____" as "Date: //____". Which runs pair is decided by CommonMark's own emphasis algorithm
    ///   (`emphasisPairs`), not by adjacency: in "**Fever**, **chills**" the run after "Fever" closes its own span
    ///   and the next one opens a new span, so emphasis around words is unaffected (fix round 1 of plan 024 Task 4:
    ///   an adjacency rule leaked "**" there).
    ///
    /// Inline code and links are copied untouched: CommonMark reads no escapes inside them, so an added backslash
    /// would show ("`2*3`" copied as "2\*3", "<https://example.com/~user>" and the bare
    /// "https://example.com/~user" as ".../\~user"). An escape the source already wrote ("25\~50") is kept as
    /// written.
    private static func protectLiterals(_ chars: [Character]) -> String {
        let verbatim = verbatimSpans(in: chars, bareLinks: true)
        var escaped = Set<Int>()
        var index = 0
        while index < chars.count {
            if let span = verbatim.first(where: { $0.lowerBound == index }) {
                index = span.upperBound
                continue
            }
            let character = chars[index]
            if character == "\\", index + 1 < chars.count, isASCIIPunctuation(chars[index + 1]) {
                index += 2
                continue
            }
            switch character {
            case "~", "`":
                escaped.insert(index)
                index += 1
            case "*":
                let length = runLength(of: character, in: chars, at: index)
                if isBetweenWordCharacters(chars, start: index, length: length) {
                    escaped.formUnion(index..<(index + length))
                }
                index += length
            default:
                index += 1
            }
        }
        // The delimiters the parser would use for emphasis around letter-free content, round by round: keeping
        // them literal can let the remaining runs pair differently, so the pairing is recomputed until none is left.
        while true {
            let runs = delimiterRuns(chars, verbatim: verbatim, escaped: escaped)
            let letterFree = emphasisPairs(runs).filter { !chars[$0.inner].contains(where: isLetterOrDigit) }
            guard !letterFree.isEmpty else { break }
            for pair in letterFree {
                escaped.formUnion(pair.openerUsed)
                escaped.formUnion(pair.closerUsed)
            }
        }
        var result = ""
        result.reserveCapacity(chars.count + escaped.count)
        for (position, character) in chars.enumerated() {
            if escaped.contains(position) { result.append("\\") }
            result.append(character)
        }
        return result
    }

    // MARK: - Emphasis pairing (CommonMark spec 6.4, "process emphasis")

    /// A run of `*` or `_` and whether CommonMark lets it open or close emphasis (its flanking rules, with the line's
    /// start and end counted as spaces).
    private struct DelimiterRun {
        let range: Range<Int>
        let character: Character
        let canOpen: Bool
        let canClose: Bool

        init(_ chars: [Character], _ range: Range<Int>) {
            let before: Character? = range.lowerBound > 0 ? chars[range.lowerBound - 1] : nil
            let after: Character? = range.upperBound < chars.count ? chars[range.upperBound] : nil
            let spaceBefore = before?.isWhitespace ?? true
            let spaceAfter = after?.isWhitespace ?? true
            let punctuationBefore = before.map(MarkdownInline.isFlankingPunctuation) ?? false
            let punctuationAfter = after.map(MarkdownInline.isFlankingPunctuation) ?? false
            let leftFlanking = !spaceAfter && (!punctuationAfter || spaceBefore || punctuationBefore)
            let rightFlanking = !spaceBefore && (!punctuationBefore || spaceAfter || punctuationAfter)
            self.range = range
            character = chars[range.lowerBound]
            if character == "_" {
                canOpen = leftFlanking && (!rightFlanking || punctuationBefore)
                canClose = rightFlanking && (!leftFlanking || punctuationAfter)
            } else {
                canOpen = leftFlanking
                canClose = rightFlanking
            }
        }
    }

    /// Punctuation as Foundation's parser reads it for flanking: ASCII punctuation and Unicode's punctuation
    /// categories, not other symbols (measured: in "x*→*y" the arrow is italic, so "→" counts as a letter here).
    private static func isFlankingPunctuation(_ character: Character) -> Bool {
        isASCIIPunctuation(character) || character.isPunctuation
    }

    /// The `*`/`_` runs of one line outside `verbatim` spans: maximal sequences of one delimiter not escaped by the
    /// source or by `escaped` (a delimiter kept literal is ordinary text to the parser, so it ends a run).
    private static func delimiterRuns(_ chars: [Character], verbatim: [Range<Int>], escaped: Set<Int>) -> [DelimiterRun]
    {
        var runs: [DelimiterRun] = []
        var index = 0
        while index < chars.count {
            if let span = verbatim.first(where: { $0.lowerBound == index }) {
                index = span.upperBound
                continue
            }
            let character = chars[index]
            if character == "\\", index + 1 < chars.count, isASCIIPunctuation(chars[index + 1]) {
                index += 2
                continue
            }
            guard character == "*" || character == "_", !escaped.contains(index) else {
                index += 1
                continue
            }
            var end = index + 1
            while end < chars.count, chars[end] == character, !escaped.contains(end) { end += 1 }
            runs.append(DelimiterRun(chars, index..<end))
            index = end
        }
        return runs
    }

    /// One emphasis the parser makes: the characters it encloses and the delimiters it uses on each side.
    private typealias EmphasisPair = (inner: Range<Int>, openerUsed: Range<Int>, closerUsed: Range<Int>)

    /// CommonMark's emphasis algorithm over one line's runs: each closer takes the nearest earlier opener of the
    /// same character (skipping a match the "multiple of 3" rule forbids), two delimiters at a time when both runs
    /// have two left, and the runs between them stop counting. Returns each pairing with the characters it encloses
    /// and the delimiter positions it uses.
    private static func emphasisPairs(_ runs: [DelimiterRun]) -> [EmphasisPair] {
        // The delimiters of each run not yet used: an opener gives up its last ones, a closer its first ones.
        var unused = runs.map(\.range)
        var onStack = Array(repeating: true, count: runs.count)
        var pairs: [EmphasisPair] = []
        var closer = 0
        while closer < runs.count {
            guard onStack[closer], runs[closer].canClose, !unused[closer].isEmpty else {
                closer += 1
                continue
            }
            var match: Int?
            for opener in stride(from: closer - 1, through: 0, by: -1)
            where onStack[opener] && runs[opener].canOpen && runs[opener].character == runs[closer].character
                && !unused[opener].isEmpty
            {
                let openerLength = runs[opener].range.count
                let closerLength = runs[closer].range.count
                let multipleOfThree =
                    (runs[opener].canClose || runs[closer].canOpen) && (openerLength + closerLength) % 3 == 0
                    && !(openerLength % 3 == 0 && closerLength % 3 == 0)
                if !multipleOfThree {
                    match = opener
                    break
                }
            }
            guard let opener = match else {
                if !runs[closer].canOpen { onStack[closer] = false }
                closer += 1
                continue
            }
            let openerLeft = unused[opener]
            let closerLeft = unused[closer]
            let use = openerLeft.count >= 2 && closerLeft.count >= 2 ? 2 : 1
            pairs.append(
                (
                    openerLeft.upperBound..<closerLeft.lowerBound,
                    (openerLeft.upperBound - use)..<openerLeft.upperBound,
                    closerLeft.lowerBound..<(closerLeft.lowerBound + use)
                ))
            for between in (opener + 1)..<closer { onStack[between] = false }
            unused[opener] = openerLeft.lowerBound..<(openerLeft.upperBound - use)
            unused[closer] = (closerLeft.lowerBound + use)..<closerLeft.upperBound
            if unused[opener].isEmpty { onStack[opener] = false }
            if unused[closer].isEmpty {
                onStack[closer] = false
                closer += 1
            }
        }
        return pairs
    }

    // MARK: - Scanning helpers

    /// The spans of one line Foundation reads verbatim, escapes included, so nothing may be escaped inside them:
    /// inline code (a backtick run opens a span that the next run of exactly the same length closes) and autolinks
    /// (`<https://…>`, `<name@example.com>`), whichever starts first, as CommonMark decides; a backslash-escaped
    /// backtick or "<" opens neither. One deliberate difference: a backtick run between two Latin letters or digits
    /// never opens a code span. With `bareLinks`, also GitHub's extended autolinks, which Foundation links without
    /// angle brackets (fix round 1): a bare URL with all of its space-delimited token (`bareLinkEnd`), and then, in
    /// the text those spans leave, email addresses (`emailEnd`) — Foundation finds addresses last, after its inline
    /// parsing, so a URL or inline code wins over an address it touches ("user@www.http://…" links the URL).
    private static func verbatimSpans(in chars: [Character], bareLinks: Bool) -> [Range<Int>] {
        var spans: [Range<Int>] = []
        var index = 0
        while index < chars.count {
            if chars[index] == "\\", index + 1 < chars.count, isASCIIPunctuation(chars[index + 1]) {
                index += 2
                continue
            }
            if chars[index] == "<", let end = autolinkEnd(in: chars, at: index) {
                spans.append(index..<end)
                index = end
                continue
            }
            if bareLinks, let end = bareLinkEnd(in: chars, at: index) {
                spans.append(index..<end)
                index = end
                continue
            }
            guard chars[index] == "`" else {
                index += 1
                continue
            }
            let run = runLength(of: "`", in: chars, at: index)
            if !isBetweenWordCharacters(chars, start: index, length: run),
                let close = closingBacktickRun(in: chars, from: index + run, length: run)
            {
                spans.append(index..<(close + run))
                index = close + run
            } else {
                index += run
            }
        }
        guard bareLinks else { return spans }
        var emails: [Range<Int>] = []
        var gapStart = 0
        for span in spans + [chars.count..<chars.count] {
            var index = gapStart
            while index < span.lowerBound {
                if let end = emailEnd(in: chars, at: index, gap: gapStart..<span.lowerBound) {
                    emails.append(index..<end)
                    index = end
                } else {
                    index += 1
                }
            }
            gapStart = span.upperBound
        }
        return (spans + emails).sorted { $0.lowerBound < $1.lowerBound }
    }

    /// The end of the bare URL starting at `start`, as cmark-gfm (Foundation's parser) finds one, measured against
    /// Foundation: `http://`, `https://` or `ftp://` in any case, not right after an ASCII letter ("xhttps://" is not
    /// one), or a lowercase `www.` at the line's start or after a space or one of `*_~(`; then a host that starts
    /// with a letter or digit and has no "_" in its last two labels ("my_host.com" is not one). The span runs to the
    /// next space or "<", including the trailing punctuation GitHub leaves outside the link (`…/a~`, `…/b.`, a
    /// closing ")"): GitHub trims that tail by its characters, and a backslash added in it would stop the trim and
    /// become part of the link.
    private static func bareLinkEnd(in chars: [Character], at start: Int) -> Int? {
        var hostStart: Int?
        let scheme = ["https://", "http://", "ftp://"].first { matches($0, in: chars, at: start, ignoringCase: true) }
        if let scheme, start == 0 || !(chars[start - 1].isASCII && chars[start - 1].isLetter) {
            hostStart = start + scheme.count
        }
        if hostStart == nil, matches("www.", in: chars, at: start, ignoringCase: false),
            start == 0 || chars[start - 1].isWhitespace || "*_~(".contains(chars[start - 1])
        {
            hostStart = start
        }
        guard let hostStart, hostStart < chars.count, chars[hostStart].isLetter || chars[hostStart].isNumber else {
            return nil
        }
        var hostEnd = hostStart
        while hostEnd < chars.count,
            chars[hostEnd].isLetter || chars[hostEnd].isNumber || "-_.".contains(chars[hostEnd])
        {
            hostEnd += 1
        }
        let labels = String(chars[hostStart..<hostEnd]).split(separator: ".", omittingEmptySubsequences: false)
        guard !labels.suffix(2).contains(where: { $0.contains("_") }) else { return nil }
        var end = hostEnd
        while end < chars.count, !chars[end].isWhitespace, chars[end] != "<" { end += 1 }
        return end
    }

    /// GitHub's extended email autolink starting at `start` (the first character of the address) within `gap` (the
    /// text the other spans leave): ASCII letters, digits and `.+-_` before one "@", then letters, digits, `-`, `_`
    /// and "." (a "." only before a letter or digit, at least one), ending on a letter ("user@example.com_" is not
    /// one).
    private static func emailEnd(in chars: [Character], at start: Int, gap: Range<Int>) -> Int? {
        func isLocal(_ character: Character) -> Bool {
            character.isASCII && (character.isLetter || character.isNumber || ".+-_".contains(character))
        }
        func isAlphanumeric(_ character: Character) -> Bool {
            character.isASCII && (character.isLetter || character.isNumber)
        }
        guard isLocal(chars[start]), start == gap.lowerBound || !isLocal(chars[start - 1]) else { return nil }
        var at = start
        while at < gap.upperBound, isLocal(chars[at]) { at += 1 }
        guard at < gap.upperBound, chars[at] == "@" else { return nil }
        var end = at + 1
        var periods = 0
        while end < gap.upperBound {
            let character = chars[end]
            if isAlphanumeric(character) || character == "-" || character == "_" {
                end += 1
            } else if character == ".", end + 1 < gap.upperBound, isAlphanumeric(chars[end + 1]) {
                periods += 1
                end += 1
            } else {
                break
            }
        }
        guard periods > 0, chars[end - 1].isASCII, chars[end - 1].isLetter else { return nil }
        return end
    }

    private static func matches(_ prefix: String, in chars: [Character], at start: Int, ignoringCase: Bool) -> Bool {
        let wanted = Array(prefix)
        guard start + wanted.count <= chars.count else { return false }
        return zip(chars[start..<(start + wanted.count)], wanted).allSatisfy { have, want in
            ignoringCase ? have.lowercased() == want.lowercased() : have == want
        }
    }

    /// CommonMark's URI autolink (a 2–32 character scheme, ":", then no space, "<" or ">") and email autolink.
    private static let uriAutolink = try! NSRegularExpression(pattern: "^[A-Za-z][A-Za-z0-9+.\\-]{1,31}:[^\\s<>]*$")
    private static let emailAutolink = try! NSRegularExpression(
        pattern: "^[a-zA-Z0-9.!#$%&'*+/=?^_`{|}~-]+@[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?"
            + "(?:\\.[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$")

    /// The end (just past ">") of the autolink starting at `start`, or nil when the "<" there does not open one.
    private static func autolinkEnd(in chars: [Character], at start: Int) -> Int? {
        guard
            let close = chars[(start + 1)...].firstIndex(where: { $0 == ">" || $0 == "<" || $0.isWhitespace }),
            chars[close] == ">", close > start + 1
        else { return nil }
        let inner = String(chars[(start + 1)..<close])
        let range = NSRange(inner.startIndex..., in: inner)
        let isAutolink = [uriAutolink, emailAutolink].contains { $0.firstMatch(in: inner, range: range) != nil }
        return isAutolink ? close + 1 : nil
    }

    private static func closingBacktickRun(in chars: [Character], from start: Int, length: Int) -> Int? {
        var index = start
        while index < chars.count {
            guard chars[index] == "`" else {
                index += 1
                continue
            }
            let run = runLength(of: "`", in: chars, at: index)
            if run == length { return index }
            index += run
        }
        return nil
    }

    private static func runLength(of character: Character, in chars: [Character], at start: Int) -> Int {
        var end = start
        while end < chars.count, chars[end] == character { end += 1 }
        return end - start
    }

    /// True when the run at `start..<start+length` has a Latin letter or digit directly on both sides.
    private static func isBetweenWordCharacters(_ chars: [Character], start: Int, length: Int) -> Bool {
        let after = start + length
        guard start > 0, after < chars.count else { return false }
        return isLatinWordCharacter(chars[start - 1]) && isLatinWordCharacter(chars[after])
    }

    private static func isLatinWordCharacter(_ character: Character) -> Bool {
        character.isASCII && (character.isLetter || character.isNumber)
    }

    private static func isLetterOrDigit(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
    }

    /// CommonMark's escapable characters: ASCII punctuation.
    private static func isASCIIPunctuation(_ character: Character) -> Bool {
        character.isASCII && (character.isPunctuation || character.isSymbol)
    }
}
