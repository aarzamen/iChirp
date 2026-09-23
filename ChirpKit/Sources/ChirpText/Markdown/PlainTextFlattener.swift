// UX audit F23 / plan 023 owner decision: "formatted view, plain copy." Copy puts clean plain text on the
// clipboard — no `**`, `##`, backticks or tags — so a generated document pastes well into an EMR.

import Foundation

/// Turns a generated document's Markdown into clean plain text for the clipboard.
///
/// - A heading (`#`…`######`, or a line that is a single bold run — every built-in template's section-name style,
///   `**Subjective**`) becomes its text on its own line, followed by a blank line.
/// - A bullet becomes `"- "` (`PlainTextFlattener.bulletMarker`) at every nesting level, each level indented two
///   more spaces. `"- "` was chosen over `"• "`: a hyphen types and pastes identically everywhere, where a bullet
///   glyph can arrive as `?` or get stripped by a strict EMR field.
/// - A numbered item keeps its own number, exactly as written (never renumbered).
/// - Paragraphs are separated by one blank line.
/// - Code is shown as plain text — its fence markers are dropped and its content is never re-parsed as Markdown.
///
/// Every word of the source survives, in order (`PlainTextFlattenerPropertyTests`): the only characters this drops
/// are Markdown's own structural syntax (`#`, `*`, `_`, `` ` ``, list markers, fences) — never a letter, digit or
/// word the source actually wrote.
public enum PlainTextFlattener {
    /// The bullet marker every unordered item gets, at every nesting level. Documented here because it is a
    /// product decision (plan 023), not an implementation detail — read it before assuming "•" instead.
    public static let bulletMarker = "- "
    static let indentUnit = "  "

    public static func flatten(_ markdown: String) -> String {
        MarkdownBlockParser.parse(markdown)
            .map(render)
            .joined(separator: "\n\n")
    }

    private static func render(_ block: MarkdownBlock) -> String {
        switch block {
        case .heading(_, let text):
            return MarkdownInline.plain(text)
        case .paragraph(let text):
            // A paragraph can hold several source lines (soft-wrapped); each keeps its own line break.
            return text.components(separatedBy: "\n")
                .map(MarkdownInline.plain)
                .joined(separator: "\n")
        case .list(let items):
            return items.map(renderItem).joined(separator: "\n")
        case .code(let text):
            return text
        }
    }

    private static func renderItem(_ item: MarkdownListItem) -> String {
        let indent = String(repeating: indentUnit, count: item.level)
        let marker = item.number.map { "\($0). " } ?? bulletMarker
        return indent + marker + MarkdownInline.plain(item.text)
    }
}
