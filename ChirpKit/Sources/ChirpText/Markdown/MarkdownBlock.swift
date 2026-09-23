// UX audit F23 / plan 023 (owner decision): generated documents render their Markdown on screen instead of showing
// `**`/`##` literally, and Copy puts clean plain text on the clipboard. This file is the pure, testable half: a
// small line-based block parser (no third-party dependency) shared by `MarkdownDocument` (the SwiftUI renderer) and
// `PlainTextFlattener` (the Copy-side plain-text writer). Inline emphasis inside a block's `text` — bold, italic,
// inline code, links — is resolved separately by `MarkdownInline`.

import Foundation

/// One block of a generated document's Markdown.
public enum MarkdownBlock: Sendable, Equatable {
    /// An ATX heading (`#` … `######`), or a line that is a single bold run and nothing else — the shape every
    /// built-in template uses for its section names (`**Subjective**`, `**Key Points**`). `level` is 1–6 for a real
    /// `#` heading; a bold-only pseudo-heading is level 2.
    case heading(level: Int, text: String)
    /// One or more source lines with no list or heading marker, joined by "\n" (blank lines end a paragraph).
    case paragraph(String)
    /// A run of consecutive list lines (bulleted, numbered, or both mixed, as the source interleaves them).
    case list([MarkdownListItem])
    /// A fenced ``` code block: shown and copied as plain text, its fence markers dropped, its content never run
    /// through inline Markdown parsing.
    case code(String)
}

/// One line of a `MarkdownBlock.list`.
public struct MarkdownListItem: Sendable, Equatable {
    /// 0 for a top-level item; each two leading spaces (or one tab) of source indentation is one more level.
    public let level: Int
    /// The item's own number for an ordered item ("keep their numbers" — plan 023); nil for a bulleted item.
    public let number: Int?
    /// The item's inline text, marker stripped.
    public let text: String

    public init(level: Int, number: Int?, text: String) {
        self.level = level
        self.number = number
        self.text = text
    }
}

/// Splits a generated document's Markdown into `MarkdownBlock`s. Deterministic, synchronous, no third-party
/// dependency — safe to call from a SwiftUI `body`, a Copy action, or a test on the Mac.
public enum MarkdownBlockParser {
    public static func parse(_ markdown: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraphLines: [String] = []
        var listItems: [MarkdownListItem] = []
        var codeLines: [String] = []
        var inCode = false

        func flushParagraph() {
            guard !paragraphLines.isEmpty else { return }
            let text = paragraphLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { blocks.append(.paragraph(text)) }
            paragraphLines = []
        }
        func flushList() {
            guard !listItems.isEmpty else { return }
            blocks.append(.list(listItems))
            listItems = []
        }

        let normalized = markdown.replacingOccurrences(of: "\r\n", with: "\n")
        for rawLine in normalized.components(separatedBy: "\n") {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)

            // A fence line toggles code mode, whether it opens (optionally with a language tag) or closes.
            if trimmed.hasPrefix("```") {
                if inCode {
                    blocks.append(.code(codeLines.joined(separator: "\n")))
                    codeLines = []
                    inCode = false
                } else {
                    flushParagraph()
                    flushList()
                    inCode = true
                }
                continue
            }
            if inCode {
                codeLines.append(rawLine)
                continue
            }
            if trimmed.isEmpty {
                flushParagraph()
                flushList()
                continue
            }
            if let heading = headingLine(trimmed) {
                flushParagraph()
                flushList()
                blocks.append(.heading(level: heading.level, text: heading.text))
                continue
            }
            if let item = listItemLine(rawLine) {
                flushParagraph()
                listItems.append(item)
                continue
            }
            flushList()
            paragraphLines.append(trimmed)
        }
        flushParagraph()
        flushList()
        // An unclosed fence (truncated output mid-stream): show what came through rather than lose it.
        if inCode, !codeLines.isEmpty {
            blocks.append(.code(codeLines.joined(separator: "\n")))
        }
        return blocks
    }

    // MARK: - Line classifiers

    /// A real ATX heading needs "# " (a space after the hashes, CommonMark's own rule) — this is what keeps "#1
    /// rule for success" and "#hashtag" from being misread as headings. A bold-only line is a heading only when the
    /// bold run spans the *entire* trimmed line; "**a** and **b**" is two inline runs inside a paragraph, not one.
    private static func headingLine(_ line: String) -> (level: Int, text: String)? {
        if line.hasPrefix("#") {
            let hashes = line.prefix { $0 == "#" }.count
            guard hashes <= 6 else { return nil }
            let rest = line.dropFirst(hashes)
            guard rest.hasPrefix(" ") else { return nil }
            let text = rest.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return nil }
            return (hashes, text)
        }
        for marker in ["**", "__"] {
            guard line.hasPrefix(marker), line.hasSuffix(marker), line.count > marker.count * 2 else { continue }
            let inner = String(line.dropFirst(marker.count).dropLast(marker.count))
            if !inner.isEmpty, !inner.contains(marker) {
                return (2, inner)
            }
        }
        return nil
    }

    private static let bulletMarkers = ["- ", "* ", "+ ", "• "]

    /// A numbered marker needs a period or close-paren *and a following space* right after 1–4 digits — this is
    /// what keeps "120/80 mmHg" (a slash, not a list) and "3.5 mg" (a decimal, not "item 3") from being read as
    /// list items. Two leading spaces (or one tab) of indentation is one nesting level.
    private static func listItemLine(_ rawLine: String) -> MarkdownListItem? {
        let indentWidth = rawLine.prefix { $0 == " " || $0 == "\t" }
            .reduce(0) { $0 + ($1 == "\t" ? 2 : 1) }
        let level = indentWidth / 2
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return nil }

        for marker in bulletMarkers where line.hasPrefix(marker) {
            let text = String(line.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return nil }
            return MarkdownListItem(level: level, number: nil, text: text)
        }

        let digits = line.prefix { $0.isNumber }
        guard !digits.isEmpty, digits.count <= 4, let number = Int(digits) else { return nil }
        let rest = line.dropFirst(digits.count)
        guard rest.hasPrefix(". ") || rest.hasPrefix(") ") else { return nil }
        let text = String(rest.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        return MarkdownListItem(level: level, number: number, text: text)
    }
}
