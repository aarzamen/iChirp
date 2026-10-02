import ChirpCore
import Foundation

/// Word (.docx) documents: unzips `word/document.xml` and reads its paragraphs (`w:p`) and runs of text (`w:t`), with
/// tabs, line breaks, non-breaking hyphens and symbol-font characters (`w:sym`, through `SymbolFontMap`). Deleted text
/// in tracked changes (`w:delText`), field codes (`w:instrText`) and tab-stop definitions are skipped. Content Word
/// writes twice for older readers (`mc:AlternateContent`: a text box's drawing and its VML copy) is read once: the
/// first `mc:Choice`, and the `mc:Fallback` only when that choice held no text. The title comes from
/// `docProps/core.xml` (`dc:title`). Apple's DOCX importer is macOS-only, hence this reader.
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

    /// Collects the text of every `w:p` in `word/document.xml`. A text box's paragraphs sit inside a run of the
    /// paragraph that anchors it, so open paragraphs form a stack: the box's paragraphs come out before their anchor.
    private final class BodyParser: NSObject, XMLParserDelegate {
        private(set) var paragraphs: [String] = []
        /// Paragraphs started and not yet ended, innermost last.
        private var open: [String] = []
        private var inText = false
        /// Inside `w:tabs` (paragraph properties): its `w:tab` elements are tab stops, not tab characters.
        private var tabStopDepth = 0
        /// Characters emitted so far; tells whether an `mc:Choice` produced any text.
        private var emitted = 0
        /// When > 0, every event is ignored until the element that started the skip ends.
        private var skipDepth = 0
        /// One entry per open `mc:AlternateContent`.
        private var alternates: [Alternate] = []
        private(set) var unmappedSymbols = 0

        private struct Alternate {
            var sawChoice = false
            var choiceStart = 0
            var choiceProducedText = false
        }

        static func paragraphs(in data: Data) throws -> [String] {
            let parser = XMLParser(data: data)
            let delegate = BodyParser()
            parser.delegate = delegate
            guard parser.parse() else {
                throw DocumentExtractionError.malformed(.docx, "its document body is not valid XML.")
            }
            if delegate.unmappedSymbols > 0 {
                Log.logger("documents").notice(
                    "docx_symbols_unmapped count=\(delegate.unmappedSymbols, privacy: .public)")
            }
            return delegate.paragraphs + delegate.open.filter { !$0.isEmpty }
        }

        private func emit(_ text: String) {
            guard !text.isEmpty else { return }
            if open.isEmpty { open.append("") }
            open[open.count - 1] += text
            emitted += text.count
        }

        private func emitSymbol(font: String?, code: String?) {
            let character = SymbolFontMap.character(font: font, code: code)
            if character == SymbolFontMap.replacement { unmappedSymbols += 1 }
            emit(String(character))
        }

        func parser(
            _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
            qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]
        ) {
            if skipDepth > 0 {
                skipDepth += 1
                return
            }
            switch elementName {
            case "w:p": open.append("")
            case "w:t": inText = true
            case "w:tabs": tabStopDepth += 1
            case "w:tab", "w:ptab": if tabStopDepth == 0 { emit("\t") }
            case "w:br", "w:cr": emit("\n")
            case "w:noBreakHyphen": emit("\u{2011}")
            case "w:sym": emitSymbol(font: attributeDict["w:font"], code: attributeDict["w:char"])
            case "w16se:symEx": emitSymbol(font: attributeDict["w16se:font"], code: attributeDict["w16se:char"])
            case "mc:AlternateContent": alternates.append(Alternate())
            case "mc:Choice":
                guard !alternates.isEmpty, !alternates[alternates.count - 1].sawChoice else {
                    // A second choice: the first one is the content this reader uses.
                    skipDepth = 1
                    return
                }
                alternates[alternates.count - 1].sawChoice = true
                alternates[alternates.count - 1].choiceStart = emitted
            case "mc:Fallback":
                if alternates.last?.choiceProducedText == true { skipDepth = 1 }
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if inText, skipDepth == 0 { emit(string) }
        }

        func parser(
            _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?
        ) {
            if skipDepth > 0 {
                skipDepth -= 1
                return
            }
            switch elementName {
            case "w:t":
                inText = false
            case "w:tabs":
                tabStopDepth = max(0, tabStopDepth - 1)
            case "w:p":
                paragraphs.append(open.popLast() ?? "")
            case "mc:Choice":
                if !alternates.isEmpty {
                    alternates[alternates.count - 1].choiceProducedText =
                        emitted > alternates[alternates.count - 1].choiceStart
                }
            case "mc:AlternateContent":
                _ = alternates.popLast()
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
