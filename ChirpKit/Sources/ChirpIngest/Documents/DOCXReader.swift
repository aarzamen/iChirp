import ChirpCore
import Foundation

/// Word (.docx) documents: unzips `word/document.xml` and reads its paragraphs (`w:p`) and runs of text (`w:t`), with
/// tabs and line breaks. Deleted text in tracked changes (`w:delText`) and field codes (`w:instrText`) are skipped.
/// The title comes from `docProps/core.xml` (`dc:title`). Apple's DOCX importer is macOS-only, hence this reader.
enum DOCXReader {
    static func read(_ data: Data) throws -> ExtractedDocument {
        let archive: ZipArchiveReader
        do {
            archive = try ZipArchiveReader(data: data)
        } catch ZipArchiveReader.ZipError.notAZipFile {
            throw DocumentExtractionError.malformed(.docx, "it is not a Word (.docx) file.")
        } catch {
            throw DocumentExtractionError.malformed(.docx, describe(error))
        }
        let body: Data
        do {
            body = try archive.contents(of: "word/document.xml")
        } catch ZipArchiveReader.ZipError.missingEntry {
            throw DocumentExtractionError.malformed(.docx, "it has no document body (word/document.xml).")
        } catch {
            throw DocumentExtractionError.malformed(.docx, describe(error))
        }
        let paragraphs = try BodyParser.paragraphs(in: body)
        let text = DocumentTextExtractor.tidy(paragraphs.joined(separator: "\n\n"))
        guard !text.isEmpty else { throw DocumentExtractionError.noText(.docx) }
        let title = (try? archive.contents(of: "docProps/core.xml")).flatMap(CoreTitleParser.title(in:))
        return ExtractedDocument(text: text, title: DocumentTextExtractor.plausibleTitle(title))
    }

    private static func describe(_ error: any Error) -> String {
        switch error as? ZipArchiveReader.ZipError {
        case .unsupported(let what): "Parakeet can’t read \(what) in Word files."
        case .damaged(let what): "\(what)."
        case .tooLarge: "it is too large to read."
        default: "it couldn’t be unzipped."
        }
    }

    /// Collects the text of every `w:p` in `word/document.xml`.
    private final class BodyParser: NSObject, XMLParserDelegate {
        private(set) var paragraphs: [String] = []
        private var current = ""
        private var inText = false

        static func paragraphs(in data: Data) throws -> [String] {
            let parser = XMLParser(data: data)
            let delegate = BodyParser()
            parser.delegate = delegate
            guard parser.parse() else {
                throw DocumentExtractionError.malformed(.docx, "its document body is not valid XML.")
            }
            return delegate.paragraphs
        }

        func parser(
            _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
            qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]
        ) {
            switch elementName {
            case "w:t": inText = true
            case "w:tab": current += "\t"
            case "w:br", "w:cr": current += "\n"
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if inText { current += string }
        }

        func parser(
            _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?
        ) {
            switch elementName {
            case "w:t":
                inText = false
            case "w:p":
                paragraphs.append(current)
                current = ""
            default:
                break
            }
        }
    }

    /// Reads `dc:title` from `docProps/core.xml`.
    private final class CoreTitleParser: NSObject, XMLParserDelegate {
        private var title = ""
        private var inTitle = false

        static func title(in data: Data) -> String? {
            let parser = XMLParser(data: data)
            let delegate = CoreTitleParser()
            parser.delegate = delegate
            guard parser.parse() else { return nil }
            let trimmed = delegate.title.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        func parser(
            _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
            qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]
        ) {
            if elementName == "dc:title" { inTitle = true }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if inTitle { title += string }
        }

        func parser(
            _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?
        ) {
            if elementName == "dc:title" { inTitle = false }
        }
    }
}
