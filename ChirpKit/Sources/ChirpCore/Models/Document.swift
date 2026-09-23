import Foundation

/// The formats a document item can come from (M5). A document has text but no audio and no word timings.
/// Contract: `spec/contracts/document-items-v1.md`.
public enum DocumentFormat: String, Codable, Sendable, CaseIterable {
    case pdf
    case plainText = "txt"
    case markdown = "md"
    case rtf
    case html
    case docx

    /// The format of a file with this extension (case-insensitive), or nil when it is not a document Parakeet reads.
    public init?(fileExtension: String) {
        switch fileExtension.lowercased() {
        case "pdf": self = .pdf
        case "txt", "text": self = .plainText
        case "md", "markdown", "mdown", "mkd": self = .markdown
        case "rtf": self = .rtf
        case "html", "htm", "xhtml": self = .html
        case "docx": self = .docx
        default: return nil
        }
    }

    /// The format of `url`'s file, by extension.
    public init?(url: URL) {
        self.init(fileExtension: url.pathExtension)
    }

    /// Short label for rows and the document screen, e.g. "PDF", "Word".
    public var displayName: String {
        switch self {
        case .pdf: "PDF"
        case .plainText: "Text"
        case .markdown: "Markdown"
        case .rtf: "RTF"
        case .html: "HTML"
        case .docx: "Word"
        }
    }
}

/// One page of a document's text, as extracted (M5; PDFs only).
public struct DocumentPage: Codable, Sendable, Equatable {
    /// Where the page's text came from.
    public enum Method: String, Codable, Sendable {
        /// The PDF's own text layer (PDFKit).
        case textLayer
        /// On-device text recognition of the rendered page (Vision), for scanned or image-only pages.
        case ocr
        /// Neither found any text (a blank page or an image without words).
        case empty

        /// An unknown value (a newer build wrote it) reads as `.textLayer`, so the row stays readable.
        public init(from decoder: any Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Method(rawValue: raw) ?? .textLayer
        }
    }

    /// 1-based page number.
    public var number: Int
    public var text: String
    public var method: Method

    public init(number: Int, text: String, method: Method) {
        self.number = number
        self.text = text
        self.method = method
    }
}

extension Transcription {
    /// Whether this item is a document (text only: no player, no word timings, no SRT/VTT).
    public var isDocument: Bool { sourceType == .document }

    /// Whether this item is typed or pasted text (plan 022). Shown like a document: text only.
    public var isTextItem: Bool { sourceType == .text }

    /// Whether this item is text without audio or timings (a document or a text item): the document screen, no player.
    public var isTextOnly: Bool { isDocument || isTextItem }

    /// How many PDF pages were read with OCR (0 for other items).
    public var ocrPageCount: Int {
        documentPages?.filter { $0.method == .ocr }.count ?? 0
    }
}
