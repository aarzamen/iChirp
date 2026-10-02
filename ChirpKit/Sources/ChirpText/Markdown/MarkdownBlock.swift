// UX audit F23 / plan 023 (owner decision): generated documents render their Markdown on screen instead of showing
// `**`/`##` literally, and Copy puts clean plain text on the clipboard. This file is the pure, testable half: a
// small line-based block parser (no third-party dependency) shared by `MarkdownDocument` (the SwiftUI renderer) and
// `PlainTextFlattener` (the Copy-side plain-text writer), and since plan 024 Task 4 by the PDF/Word exports
// (`ChirpExport.ExportDocument.text`), so all four read a document the same way. Inline emphasis inside a block's
// `text` — bold, italic, inline code, links — is resolved separately by `MarkdownInline`.

import Foundation

/// One block of a generated document's Markdown.
public enum MarkdownBlock: Sendable, Equatable {
    /// An ATX heading of two to six hashes (`##` … `######`), or a line that is a single bold run and nothing else —
    /// the shape every built-in template uses for its section names (`**Subjective**`, `**Key Points**`). `level`
    /// is 2–6 for a real `#` heading; a bold-only pseudo-heading is level 2. A single `#` is never a heading (known
    /// item K1, plan 024 ruling — see `MarkdownBlockParser.headingLine`).
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
    /// An ordered item's marker exactly as the source wrote it: its digits and its "." or ")" ("2.", "2)", "07.");
    /// nil for a bulleted item. The screen, Copy and the PDF/Word exports write it back unchanged, so "2)" is never
    /// turned into "2." and "07." never into "7." (known item K2, plan 024). Defaults to the number plus ".".
    public let marker: String?

    public init(level: Int, number: Int?, text: String, marker: String? = nil) {
        self.level = level
        self.number = number
        self.text = text
        self.marker = marker ?? number.map { "\($0)." }
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

    /// A real ATX heading needs a space after the hashes (CommonMark's own rule) — this is what keeps "#1 rule for
    /// success" and "#hashtag" from being misread as headings — and **two to six** hashes.
    ///
    /// Ruling (known item K1, plan 024 Task 4): a single "#" is never a heading, although CommonMark allows it. In
    /// clinical shorthand "#" is a character with meaning — "number of" ("# of doses given: 3"), "fracture"
    /// ("# L radius"), a problem-list entry ("# HTN") — and reading it as a heading dropped it from the screen, Copy
    /// and the PDF/Word exports, so the line stays text with its "#". Every built-in template names its sections
    /// with a bold line (`BuiltInTemplates`: `**Subjective**`, `**Key Points**`), and models write `##`/`###`, so
    /// those still render as headings. Cost if wrong: a model's single-`#` title line ("# SOAP Note") shows its "#"
    /// as written — cosmetic, no character lost.
    ///
    /// A bold-only line is a heading only when the bold run spans the *entire* trimmed line ("**a** and **b**" is
    /// two inline runs inside a paragraph, not one) and holds a letter or digit (a "_____" signature blank or a
    /// "*****" divider is text, not a heading whose text is "_").
    private static func headingLine(_ line: String) -> (level: Int, text: String)? {
        if line.hasPrefix("#") {
            let hashes = line.prefix { $0 == "#" }.count
            guard (2...6).contains(hashes) else { return nil }
            let rest = line.dropFirst(hashes)
            guard rest.hasPrefix(" ") else { return nil }
            let text = rest.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return nil }
            return (hashes, text)
        }
        for marker in ["**", "__"] {
            guard line.hasPrefix(marker), line.hasSuffix(marker), line.count > marker.count * 2 else { continue }
            let inner = String(line.dropFirst(marker.count).dropLast(marker.count))
            if inner.contains(where: { $0.isLetter || $0.isNumber }), !inner.contains(marker) {
                return (2, inner)
            }
        }
        return nil
    }

    /// Ruling (plan 024 Task 4): "+" is not a bullet marker, although CommonMark allows it. In clinical writing "+"
    /// means present or positive and "-" absent or negative; as a bullet, "+ fever" was drawn "•" on screen and
    /// copied as "- fever" — the opposite finding. A "+" line stays text with its "+". Cost if wrong: a model's
    /// "+"-bulleted list shows as text lines starting with "+" (cosmetic).
    private static let bulletMarkers = ["- ", "* ", "• "]

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
        guard let delimiter = rest.first, rest.hasPrefix(". ") || rest.hasPrefix(") ") else { return nil }
        let text = String(rest.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        return MarkdownListItem(
            level: level, number: number, text: text, marker: String(digits) + String(delimiter))
    }
}
