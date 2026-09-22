import ChirpCore
import Foundation

/// A document's text as extracted, before it becomes a Library row.
public struct ExtractedDocument: Sendable, Equatable {
    /// The whole text. PDF pages are joined with a blank line.
    public var text: String
    /// Per-page text (PDFs only).
    public var pages: [DocumentPage]?
    /// The document's own title when it has a plausible one (PDF metadata, HTML `<title>`, a Markdown `# ` heading,
    /// DOCX core properties).
    public var title: String?

    public init(text: String, pages: [DocumentPage]? = nil, title: String? = nil) {
        self.text = text
        self.pages = pages
        self.title = title
    }
}

/// Why a document could not be read, worded for the person.
public enum DocumentExtractionError: Error, Equatable, LocalizedError {
    case unsupportedFormat(String)
    case unreadable(DocumentFormat)
    case passwordProtected
    case noText(DocumentFormat)
    case malformed(DocumentFormat, String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let ext):
            ext.isEmpty
                ? "Parakeet can’t read this kind of file. It reads PDF, Word (.docx), RTF, HTML, Markdown and text."
                : "Parakeet can’t read .\(ext) files. It reads PDF, Word (.docx), RTF, HTML, Markdown and text."
        case .unreadable(let format):
            "This \(format.displayName) file couldn’t be opened. It may be damaged or not really a \(format.displayName) file."
        case .passwordProtected:
            "This PDF is password-protected. Remove the password (for example in Files or Preview), then import it again."
        case .noText(let format):
            format == .pdf
                ? "No text was found in this PDF, even with text recognition."
                : "This \(format.displayName) file has no text."
        case .malformed(let format, let detail):
            "This \(format.displayName) file is damaged: \(detail)"
        }
    }
}

/// Reads a document's text on this iPhone. Nothing here uses the network.
public protocol DocumentTextExtracting: Sendable {
    /// Extracts `url`'s text as `format`. `progress(done, total)` reports pages (PDF) or 0/1 then 1/1 (others).
    /// Throws `DocumentExtractionError` (or `CancellationError`).
    func extract(
        from url: URL,
        format: DocumentFormat,
        progress: @escaping @Sendable (Int, Int) -> Void
    ) async throws -> ExtractedDocument
}

/// The app's extractor: PDFKit plus Vision OCR for PDFs, and the text readers for everything else.
public struct DocumentTextExtractor: DocumentTextExtracting {
    private let pdf: PDFTextExtractor

    /// - Parameter recognizer: reads scanned PDF pages (Vision on this device by default).
    public init(recognizer: any PageTextRecognizing = VisionPageTextRecognizer()) {
        pdf = PDFTextExtractor(recognizer: recognizer)
    }

    public func extract(
        from url: URL,
        format: DocumentFormat,
        progress: @escaping @Sendable (Int, Int) -> Void
    ) async throws -> ExtractedDocument {
        let accessing = url.startAccessingSecurityScopedResource()
        defer {
            if accessing { url.stopAccessingSecurityScopedResource() }
        }
        switch format {
        case .pdf:
            return try await pdf.extract(from: url, progress: progress)
        case .plainText, .markdown, .rtf, .html, .docx:
            throw DocumentExtractionError.unsupportedFormat(url.pathExtension)
        }
    }

    /// Collapses runs of blank lines to one, trims trailing spaces on lines and whitespace at both ends.
    static func tidy(_ text: String) -> String {
        var lines: [Substring] = []
        var blankRun = 0
        for line in text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
        {
            let trimmed = line.replacing(/[ \t\u{00A0}]+$/, with: "")
            if trimmed.trimmingCharacters(in: .whitespaces).isEmpty {
                blankRun += 1
                if blankRun > 1 { continue }
                lines.append("")
            } else {
                blankRun = 0
                lines.append(Substring(trimmed))
            }
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `raw` as a title when it looks like one: not empty, not a file name or a word processor's placeholder,
    /// at most 200 characters.
    static func plausibleTitle(_ raw: String?) -> String? {
        guard let title = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty, title.count <= 200
        else {
            return nil
        }
        let lower = title.lowercased()
        let placeholders = ["untitled", "microsoft word", "document", "title", "slide 1"]
        if placeholders.contains(where: { lower == $0 || lower.hasPrefix("\($0) -") }) {
            return nil
        }
        let fileExtensions = [".doc", ".docx", ".pdf", ".txt", ".rtf", ".htm", ".html", ".md", ".pages", ".indd"]
        if fileExtensions.contains(where: { lower.hasSuffix($0) }) {
            return nil
        }
        return title
    }
}
