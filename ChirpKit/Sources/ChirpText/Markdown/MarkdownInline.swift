// UX audit F23 / plan 023. The inline half of the Markdown pipeline: bold, italic, inline code and links inside one
// block's text, shared by `MarkdownDocument` (keeps the emphasis, for display) and `PlainTextFlattener` (drops the
// markup, keeps the words, for Copy).

import Foundation

/// Resolves inline Markdown within a single block's text (never spans blocks — a block boundary is already decided
/// by `MarkdownBlockParser`).
enum MarkdownInline {
    /// `AttributedString(markdown:)`'s `.inlineOnlyPreservingWhitespace` syntax parses bold/italic/code spans and
    /// keeps whitespace and line breaks literal (it never reflows a paragraph or invents a new block) — exactly
    /// what a heading, paragraph or list-item's text needs. It also leaves anything it cannot parse as syntax
    /// exactly as written: an unpaired "*" ("2*3", "50 * 2" is math, not italics), an unmatched "**" ("bold without
    /// close"), a "[bracket]" with no following "(url)" — verified in `MarkdownInlineTests`.
    private static let options = AttributedString.MarkdownParsingOptions(
        interpretedSyntax: .inlineOnlyPreservingWhitespace)

    /// `[label](url)` matched so the link can be rewritten before parsing — see `neutralizeLinks`.
    private static let linkPattern = try! NSRegularExpression(pattern: "\\[([^\\]]*)\\]\\(([^)]*)\\)")
    /// A "*" directly between two digits, matched so it can be escaped before parsing — see `escapeMultiplication`.
    private static let digitAsteriskPattern = try! NSRegularExpression(pattern: "(\\d)\\*(\\d)")

    /// The text with its Markdown emphasis resolved to attributes, for `Text(_:)` in `MarkdownDocument`.
    static func attributed(_ text: String) -> AttributedString {
        let safe = escapeMultiplication(neutralizeLinks(text))
        return (try? AttributedString(markdown: safe, options: options)) ?? AttributedString(safe)
    }

    /// The same text with the Markdown syntax gone and every word kept, for `PlainTextFlattener`.
    static func plain(_ text: String) -> String {
        String(attributed(text).characters)
    }

    /// Markdown link syntax renders as just the label — `AttributedString` turns "[Google](url)" into "Google" and
    /// drops "url" entirely. That would silently lose text on Copy (the owner's "no text is lost" rule, F23), so a
    /// link is rewritten to "label (url)" before parsing; both `MarkdownDocument` and `PlainTextFlattener` see the
    /// same rewritten text; the app does not otherwise use Markdown links so nothing "goes plain-text" that used to
    /// be tappable.
    private static func neutralizeLinks(_ text: String) -> String {
        guard text.contains("](") else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return linkPattern.stringByReplacingMatches(in: text, range: range, withTemplate: "$1 ($2)")
    }

    /// A single "2*3" is never mistaken for italics — CommonMark needs a *paired* delimiter, and an unmatched "*"
    /// is kept literal. But a line that writes the same multiplication twice ("2*3 tablets, 2*3 more later") gives
    /// the parser two unmatched "*"s that pair with *each other* across the words between them, corrupting both
    /// numbers (`PlainTextFlattenerPropertyTests` caught this). Escaping "\*" between two digits — CommonMark's own
    /// way to write a literal "*" — keeps every "N*N" literal, however many appear on a line, without touching real
    /// italics elsewhere ("*twice daily*" is unaffected: neither side is a digit).
    private static func escapeMultiplication(_ text: String) -> String {
        guard text.contains("*") else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return digitAsteriskPattern.stringByReplacingMatches(in: text, range: range, withTemplate: "$1\\\\*$2")
    }
}
