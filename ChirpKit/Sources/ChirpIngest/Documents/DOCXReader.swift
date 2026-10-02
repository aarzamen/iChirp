import ChirpCore
import Foundation

/// Word (.docx) documents: unzips `word/document.xml` and reads its paragraphs (`w:p`) and runs of text (`w:t`), with
/// tabs, line breaks, non-breaking hyphens and symbol-font characters (`w:sym`, and the text of a run whose font is a
/// symbol font, through `SymbolFontMap`). Tracked deletions and moved-away text (everything inside `w:del` and
/// `w:moveFrom`: their `w:delText`, symbols, hyphens, tabs and breaks), field codes (`w:instrText`) and tab-stop
/// definitions are skipped. Content Word writes twice for older readers (`mc:AlternateContent`: a text box's drawing
/// and its VML copy) is read once: the first `mc:Choice`, and the `mc:Fallback` only when that choice held no text.
/// The title comes from `docProps/core.xml` (`dc:title`). Apple's DOCX importer is macOS-only, hence this reader.
enum DOCXReader {
    /// `isCancelled` is checked after unzipping, every few hundred XML elements while parsing, and before tidying; a
    /// cancelled read throws `CancellationError`.
    static func read(_ data: Data, isCancelled: @escaping () -> Bool = { false }) throws -> ExtractedDocument {
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
        try BlockingWork.checkCancellation(isCancelled)
        let paragraphs = try BodyParser.paragraphs(in: body, isCancelled: isCancelled)
        try BlockingWork.checkCancellation(isCancelled)
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
        /// Inside `w:del` or `w:moveFrom` (tracked deletions, moved-away text): nothing there is the document's text.
        /// The empty `w:del` marker of a deleted paragraph mark opens and closes at once, so it suppresses nothing.
        private var deletedDepth = 0
        /// One entry per open `w:r`: the fonts its own `w:rFonts` names for ASCII (`w:ascii`) and for other
        /// characters (`w:hAnsi`); nil where it names none. A text box's runs sit inside a run, hence a stack.
        private var runFonts: [(ascii: String?, hAnsi: String?)] = []
        /// The names of the open elements read (not skipped), outermost first: only `w:r/w:rPr/w:rFonts` names a
        /// run's font (not a paragraph mark's `w:pPr/w:rPr`, nor the old formatting in `w:rPrChange/w:rPr`).
        private var path: [String] = []
        /// Elements seen, for the periodic cancellation check.
        private var elements = 0
        private(set) var wasCancelled = false
        private let isCancelled: () -> Bool

        private struct Alternate {
            var sawChoice = false
            var choiceStart = 0
            var choiceProducedText = false
        }

        private init(isCancelled: @escaping () -> Bool) {
            self.isCancelled = isCancelled
        }

        static func paragraphs(in data: Data, isCancelled: @escaping () -> Bool) throws -> [String] {
            let parser = XMLParser(data: data)
            let delegate = BodyParser(isCancelled: isCancelled)
            parser.delegate = delegate
            let parsed = parser.parse()
            if delegate.wasCancelled { throw CancellationError() }
            guard parsed else {
                throw DocumentExtractionError.malformed(.docx, "its document body is not valid XML.")
            }
            return delegate.collected()
        }

        /// Every paragraph, plus any text left outside one (malformed bodies), so nothing read is dropped.
        private func collected() -> [String] {
            if unmappedSymbols > 0 {
                Log.logger("documents").notice("docx_symbols_unmapped count=\(self.unmappedSymbols, privacy: .public)")
            }
            return paragraphs + open.filter { !$0.isEmpty }
        }

        /// Every 256 elements: stops the parse when the import was cancelled.
        private func checkCancellation(_ parser: XMLParser) {
            elements += 1
            guard elements % 256 == 0, isCancelled() else { return }
            wasCancelled = true
            parser.abortParsing()
        }

        private func emit(_ text: String) {
            guard !text.isEmpty, deletedDepth == 0 else { return }
            if open.isEmpty { open.append("") }
            open[open.count - 1] += text
            emitted += text.count
        }

        /// A run's `w:t` text: as written in a text font; in a symbol font (typing in Symbol stores "m" for µ, and
        /// converted .doc files store the F0xx private-use code) each character goes through `SymbolFontMap`.
        private func emitRunText(_ text: String) {
            guard deletedDepth == 0 else { return }
            let fonts = runFonts.last ?? (nil, nil)
            let isSymbolCode: (Unicode.Scalar) -> Bool = { (0xF000...0xF0FF).contains($0.value) }
            if fonts.ascii == nil, fonts.hAnsi == nil, !text.unicodeScalars.contains(where: isSymbolCode) {
                emit(text)
                return
            }
            var mapped = ""
            for scalar in text.unicodeScalars {
                // ASCII uses the ASCII font only (another slot's Symbol must not turn "mg" into "µg"); a private-use
                // F0xx code is a symbol-font code by definition, so any symbol font the run names applies to it.
                let font =
                    scalar.isASCII ? fonts.ascii : (isSymbolCode(scalar) ? fonts.hAnsi ?? fonts.ascii : fonts.hAnsi)
                if let font, SymbolFontMap.isSymbolFont(font), !scalar.properties.isWhitespace {
                    let character = SymbolFontMap.character(font: font, code: String(scalar.value, radix: 16))
                    if character == SymbolFontMap.replacement { unmappedSymbols += 1 }
                    mapped.append(character)
                } else if isSymbolCode(scalar) {
                    // A symbol-font code whose font comes from a style this reader does not read: most fonts draw
                    // nothing for it ("50 µg" would read "50 g"), so it shows as the replacement character.
                    unmappedSymbols += 1
                    mapped.append(SymbolFontMap.replacement)
                } else {
                    mapped.unicodeScalars.append(scalar)
                }
            }
            emit(mapped)
        }

        private func emitSymbol(font: String?, code: String?) {
            guard deletedDepth == 0 else { return }
            let character = SymbolFontMap.character(font: font, code: code)
            if character == SymbolFontMap.replacement { unmappedSymbols += 1 }
            emit(String(character))
        }

        func parser(
            _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
            qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]
        ) {
            checkCancellation(parser)
            if skipDepth > 0 {
                skipDepth += 1
                return
            }
            path.append(elementName)
            switch elementName {
            case "w:p": open.append("")
            case "w:r": runFonts.append((nil, nil))
            case "w:rFonts":
                if path.suffix(3).elementsEqual(["w:r", "w:rPr", "w:rFonts"]), !runFonts.isEmpty {
                    runFonts[runFonts.count - 1] = (attributeDict["w:ascii"], attributeDict["w:hAnsi"])
                }
            case "w:del", "w:moveFrom": deletedDepth += 1
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
            if inText, skipDepth == 0 { emitRunText(string) }
        }

        func parser(
            _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?
        ) {
            if skipDepth > 0 {
                skipDepth -= 1
                // Still inside the skipped element; once the element that started the skip ends, it is closed below.
                if skipDepth > 0 { return }
            }
            _ = path.popLast()
            switch elementName {
            case "w:t":
                inText = false
            case "w:r":
                _ = runFonts.popLast()
            case "w:del", "w:moveFrom":
                deletedDepth = max(0, deletedDepth - 1)
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
