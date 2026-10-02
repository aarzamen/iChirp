import ChirpCore
import Foundation

/// The two page formats (plan 022 Step 6): a PDF to read or print, a Word document to keep editing. The text formats
/// (`ExportFormat`) are unchanged.
public enum DocumentExportFormat: String, CaseIterable, Sendable {
    case pdf, docx

    public var fileExtension: String {
        switch self {
        case .pdf: "pdf"
        case .docx: "docx"
        }
    }

    public var displayName: String {
        switch self {
        case .pdf: "PDF"
        case .docx: "Word"
        }
    }
}

/// Renders an `ExportDocument` as PDF or DOCX and writes it for the share sheet.
public struct DocumentExporter: Sendable {
    public init() {}

    public func render(_ document: ExportDocument, as format: DocumentExportFormat) throws -> Data {
        switch format {
        case .pdf: try PDFDocumentRenderer().render(document)
        case .docx: try DOCXDocumentWriter().render(document)
        }
    }

    /// Writes `<title>.<pdf|docx>` into `directory` (created when missing) and returns its URL. The name follows the
    /// text exports' rule (`ExportFileName`), "document" when nothing is left of the title.
    public func write(_ document: ExportDocument, as format: DocumentExportFormat, to directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stem = ExportFileName.stem(fromTitle: document.title, fallback: "document")
        let url = directory.appendingPathComponent("\(stem).\(format.fileExtension)")
        try render(document, as: format).write(to: url, options: .atomic)
        return url
    }
}
