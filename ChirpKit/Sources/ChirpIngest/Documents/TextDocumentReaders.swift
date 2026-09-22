import ChirpCore
import Foundation

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Plain text and Markdown: UTF-8 (or a BOM-marked UTF-16), else Windows-1252. Binary data is refused.
enum PlainTextReader {
    static func read(_ data: Data, format: DocumentFormat) throws -> ExtractedDocument {
        let text = try decode(data, format: format)
        let tidied = DocumentTextExtractor.tidy(text)
        guard !tidied.isEmpty else { throw DocumentExtractionError.noText(format) }
        let title = format == .markdown ? markdownTitle(in: tidied) : nil
        return ExtractedDocument(text: tidied, title: title)
    }

    /// The text of `data`, honoring a byte-order mark; NUL bytes outside UTF-16 mean a binary file.
    static func decode(_ data: Data, format: DocumentFormat) throws -> String {
        let bytes = [UInt8](data.prefix(4))
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
            return String(decoding: data.dropFirst(3), as: UTF8.self)
        }
        if bytes.starts(with: [0xFF, 0xFE]) || bytes.starts(with: [0xFE, 0xFF]) {
            guard let text = String(data: data, encoding: .utf16) else {
                throw DocumentExtractionError.malformed(format, "its text encoding couldn’t be read.")
            }
            return text
        }
        if data.contains(0) {
            throw DocumentExtractionError.malformed(format, "it contains binary data, not text.")
        }
        if let text = String(data: data, encoding: .utf8) {
            return text
        }
        if let text = String(data: data, encoding: .windowsCP1252) {
            return text
        }
        throw DocumentExtractionError.malformed(format, "its text encoding couldn’t be read.")
    }

    /// The first `# ` (or `## `) heading, or a setext heading (`Title` over `===`), near the top of a Markdown file.
    static func markdownTitle(in text: String) -> String? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).prefix(40).map(String.init)
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("# ") || trimmed.hasPrefix("## ") {
                let heading = trimmed.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
                return DocumentTextExtractor.plausibleTitle(
                    heading.trimmingCharacters(in: CharacterSet(charactersIn: "# ")))
            }
            if index + 1 < lines.count, !trimmed.isEmpty,
                lines[index + 1].trimmingCharacters(in: .whitespaces).allSatisfy({ $0 == "=" }),
                lines[index + 1].contains("=")
            {
                return DocumentTextExtractor.plausibleTitle(trimmed)
            }
        }
        return nil
    }
}

/// HTML without WebKit: `NSAttributedString`'s HTML import must run on the main thread and loads WebKit, so a small
/// converter keeps block structure (paragraphs, headings, list items, line breaks), drops scripts, styles and markup,
/// and decodes character references. Deterministic, off the main thread, and nothing is fetched (no images, no CSS).
enum HTMLTextReader {
    static func read(_ data: Data) throws -> ExtractedDocument {
        let html = try PlainTextReader.decode(data, format: .html)
        let title = firstMatch(of: /(?is)<title[^>]*>(.*?)<\/title>/, in: html).map {
            HTMLEntities.decode(collapseSpaces($0))
        }
        let text = DocumentTextExtractor.tidy(text(fromHTML: html))
        guard !text.isEmpty else { throw DocumentExtractionError.noText(.html) }
        return ExtractedDocument(text: text, title: DocumentTextExtractor.plausibleTitle(title))
    }

    static func text(fromHTML html: String) -> String {
        var body = html
        // Drop everything that is not readable text.
        body = body.replacing(/(?is)<!--.*?-->/, with: "")
        body = body.replacing(/(?is)<(script|style|head|noscript|template|svg|iframe)\b[^>]*>.*?<\/\1\s*>/, with: "")
        // Block structure → line breaks, list items → bullets, cells → tabs.
        body = body.replacing(/(?i)<br\s*\/?>/, with: "\n")
        body = body.replacing(/(?i)<li\b[^>]*>/, with: "\n• ")
        body = body.replacing(/(?i)<\/?(td|th)\b[^>]*>/, with: "\t")
        body = body.replacing(
            /(?i)<\/?(p|div|h[1-6]|ul|ol|dl|dt|dd|tr|table|section|article|header|footer|blockquote|pre|hr|main|aside|nav|figure|figcaption|address)\b[^>]*>/,
            with: "\n\n")
        body = body.replacing(/(?s)<[^>]*>/, with: "")
        let lines = body.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            HTMLEntities.decode(collapseSpaces(String(line))).trimmingCharacters(in: .whitespaces)
        }
        return lines.joined(separator: "\n")
    }

    private static func collapseSpaces(_ text: String) -> String {
        text.replacing(/[ \t\u{00A0}\r\f]+/, with: " ")
    }

    private static func firstMatch(of regex: Regex<(Substring, Substring)>, in text: String) -> String? {
        guard let match = text.firstMatch(of: regex) else { return nil }
        return String(match.1)
    }
}

/// RTF through `NSAttributedString` (RTF is one of the document types iOS imports; no WebKit involved).
enum RichTextReader {
    static func read(_ data: Data) throws -> ExtractedDocument {
        guard data.starts(with: Data("{\\rtf".utf8)) else {
            throw DocumentExtractionError.malformed(.rtf, "it is not an RTF file.")
        }
        let attributed: NSAttributedString
        do {
            attributed = try NSAttributedString(
                data: data, options: [.documentType: NSAttributedString.DocumentType.rtf],
                documentAttributes: nil)
        } catch {
            throw DocumentExtractionError.unreadable(.rtf)
        }
        let text = DocumentTextExtractor.tidy(attributed.string.replacingOccurrences(of: "\u{2028}", with: "\n"))
        guard !text.isEmpty else { throw DocumentExtractionError.noText(.rtf) }
        return ExtractedDocument(text: text, title: DocumentTextExtractor.plausibleTitle(infoTitle(in: data)))
    }

    /// The `{\info{\title …}}` text, read from the source: the title document attribute exists only on macOS.
    static func infoTitle(in data: Data) -> String? {
        let source = String(decoding: data.prefix(64 * 1_024), as: UTF8.self)
        guard let match = source.firstMatch(of: /\\title\s+([^{}\\]+)/) else { return nil }
        return String(match.1).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
