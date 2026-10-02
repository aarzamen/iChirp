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
    /// plain-text" that used to be tappable. A link inside inline code, or one whose "[" the source escaped, is not
    /// a link and stays exactly as written.
    private static func neutralizeLinks(_ chars: [Character]) -> [Character] {
        guard chars.contains("]") else { return chars }
        let code = codeSpans(in: chars)
        func inCode(_ index: Int) -> Bool { code.contains { $0.contains(index) } }
        var result: [Character] = []
        result.reserveCapacity(chars.count + 4)
        var index = 0
        while index < chars.count {
            if let span = code.first(where: { $0.lowerBound == index }) {
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
            // regular expression used), and none of the four delimiters may sit inside inline code.
            if chars[index] == "[",
                let close = chars[(index + 1)...].firstIndex(of: "]"),
                close + 1 < chars.count, chars[close + 1] == "(",
                let end = chars[(close + 2)...].firstIndex(of: ")"),
                ![close, close + 1, end].contains(where: inCode)
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
    ///
    /// Inline code itself is copied untouched: CommonMark reads no escapes inside it, so an added backslash would
    /// show ("`2*3`" copied as "2\*3"). An escape the source already wrote ("25\~50") is kept as written.
    private static func protectLiterals(_ chars: [Character]) -> String {
        let code = codeSpans(in: chars)
        var result = ""
        result.reserveCapacity(chars.count + 8)
        var index = 0
        while index < chars.count {
            if let span = code.first(where: { $0.lowerBound == index }) {
                result.append(contentsOf: chars[span])
                index = span.upperBound
                continue
            }
            let character = chars[index]
            if character == "\\", index + 1 < chars.count, isASCIIPunctuation(chars[index + 1]) {
                result.append(character)
                result.append(chars[index + 1])
                index += 2
                continue
            }
            switch character {
            case "~", "`":
                result.append("\\")
                result.append(character)
                index += 1
            case "*":
                let run = runLength(of: character, in: chars, at: index)
                let escape = isBetweenWordCharacters(chars, start: index, length: run)
                for _ in 0..<run { result.append(contentsOf: escape ? "\\*" : "*") }
                index += run
            default:
                result.append(character)
                index += 1
            }
        }
        return result
    }

    // MARK: - Scanning helpers

    /// The inline code spans of one line, as CommonMark finds them: a backtick run opens a span that the next run
    /// of exactly the same length closes (no escapes are read inside); a backslash-escaped backtick never opens
    /// one. One deliberate difference: a backtick run between two Latin letters or digits never opens a span.
    private static func codeSpans(in chars: [Character]) -> [Range<Int>] {
        guard chars.contains("`") else { return [] }
        var spans: [Range<Int>] = []
        var index = 0
        while index < chars.count {
            if chars[index] == "\\", index + 1 < chars.count, isASCIIPunctuation(chars[index + 1]) {
                index += 2
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
        return spans
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

    /// CommonMark's escapable characters: ASCII punctuation.
    private static func isASCIIPunctuation(_ character: Character) -> Bool {
        character.isASCII && (character.isPunctuation || character.isSymbol)
    }
}
