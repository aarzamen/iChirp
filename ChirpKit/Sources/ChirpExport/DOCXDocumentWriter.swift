// Plan 022 Step 6 (plan 017 item 2): a real Word document (Office Open XML, ECMA-376). Fresh implementation: upstream
// MacParakeet writes DOCX through AppKit's `NSAttributedString.DocumentType.officeOpenXML`, which iOS does not have.
// The package is the minimal valid set of parts (content types, relationships, document, styles, numbering, core
// properties) in a ZIP written by `ZipStoreWriter`; no third-party library.

import Foundation

/// Renders an `ExportDocument` as a `.docx` Word opens: Title and Heading styles, real bullet lists, speaker and time
/// runs for transcripts, the metadata lines, and the document title in its properties.
public struct DOCXDocumentWriter: Sendable {
    public init() {}

    public func render(_ document: ExportDocument, now: Date = Date()) throws -> Data {
        var zip = ZipStoreWriter()
        try zip.add(path: "[Content_Types].xml", contents: Self.contentTypes)
        try zip.add(path: "_rels/.rels", contents: Self.packageRelationships)
        try zip.add(path: "docProps/core.xml", contents: Self.coreProperties(title: document.title, now: now))
        try zip.add(path: "word/_rels/document.xml.rels", contents: Self.documentRelationships)
        try zip.add(path: "word/styles.xml", contents: Self.styles)
        try zip.add(path: "word/numbering.xml", contents: Self.numbering)
        try zip.add(path: "word/document.xml", contents: Self.documentXML(document))
        return zip.finish()
    }

    // MARK: - document.xml

    static func documentXML(_ document: ExportDocument) -> String {
        var body = ""
        body += paragraph(style: "Title", runs: [run(document.title)])
        for line in document.metadata {
            body += paragraph(
                style: "Metadata", runs: [run("\(line.label): ", bold: true), run(line.value)])
        }
        for block in document.blocks {
            switch block {
            case .heading(let text, let level):
                body += paragraph(style: level <= 1 ? "Heading1" : "Heading2", runs: [run(text)])
            case .paragraph(let text):
                body += paragraph(style: nil, runs: [run(text)])
            case .turn(let speaker, let timestamp, let text):
                if speaker != nil || timestamp != nil {
                    var runs: [String] = []
                    if let speaker { runs.append(run(speaker, bold: true, color: "BE4E26")) }
                    if let timestamp { runs.append(run((speaker == nil ? "" : "  ") + timestamp, color: "6B6B6B")) }
                    body += paragraph(style: "Speaker", runs: runs)
                }
                body += paragraph(style: nil, runs: [run(text)])
            case .bullet(let text, let level):
                body += paragraph(style: "ListParagraph", numbering: 1, level: level, runs: [run(text)])
            case .numbered(let marker, let text, let level):
                // The marker is text, exactly as the document wrote it ("2)", "07."), not Word's own numbering.
                body += paragraph(
                    style: "ListParagraph", level: level, runs: [run("\(marker)\t" + text)], hanging: true)
            }
        }
        if let footer = document.footer {
            body += paragraph(style: "Metadata", runs: [run(footer)])
        }
        return """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" \
            xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">\
            <w:body>\(body)<w:sectPr><w:pgSz w:w="12240" w:h="15840"/>\
            <w:pgMar w:top="1080" w:right="1080" w:bottom="1080" w:left="1080" w:header="720" w:footer="720" \
            w:gutter="0"/></w:sectPr></w:body></w:document>
            """
    }

    /// `level` is a list item's nesting depth: a bullet uses that Word list level (`numbering.xml` defines 0–8), a
    /// numbered item's hanging indent moves 360 twips (a quarter inch) further in per level. Level 0 is the layout
    /// every item had before nesting was kept.
    private static func paragraph(
        style: String?, numbering: Int? = nil, level: Int = 0, runs: [String], hanging: Bool = false
    ) -> String {
        let level = min(max(level, 0), 8)
        var properties = ""
        if let style { properties += "<w:pStyle w:val=\"\(style)\"/>" }
        if let numbering {
            properties += "<w:numPr><w:ilvl w:val=\"\(level)\"/><w:numId w:val=\"\(numbering)\"/></w:numPr>"
        }
        if hanging {
            let left = 432 + 360 * level
            properties +=
                "<w:tabs><w:tab w:val=\"left\" w:pos=\"\(left)\"/></w:tabs><w:ind w:left=\"\(left)\" w:hanging=\"432\"/>"
        }
        let pPr = properties.isEmpty ? "" : "<w:pPr>\(properties)</w:pPr>"
        return "<w:p>\(pPr)\(runs.joined())</w:p>"
    }

    /// One run; line breaks inside the text become `<w:br/>`, tabs `<w:tab/>`.
    private static func run(_ text: String, bold: Bool = false, color: String? = nil) -> String {
        var properties = ""
        if bold { properties += "<w:b/>" }
        if let color { properties += "<w:color w:val=\"\(color)\"/>" }
        let rPr = properties.isEmpty ? "" : "<w:rPr>\(properties)</w:rPr>"
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        let content = lines.map { line in
            line.components(separatedBy: "\t")
                .map { "<w:t xml:space=\"preserve\">\(escape($0))</w:t>" }
                .joined(separator: "<w:tab/>")
        }.joined(separator: "<w:br/>")
        return "<w:r>\(rPr)\(content)</w:r>"
    }

    /// XML-escapes text and drops characters XML 1.0 cannot hold (control characters other than tab and newline).
    static func escape(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        for scalar in text.unicodeScalars {
            switch scalar {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            case "'": result += "&apos;"
            default:
                let value = scalar.value
                let allowed =
                    value == 0x9 || value == 0xA || value == 0xD || (0x20...0xD7FF).contains(value)
                    || (0xE000...0xFFFD).contains(value) || (0x10000...0x10FFFF).contains(value)
                if allowed { result.unicodeScalars.append(scalar) }
            }
        }
        return result
    }

    // MARK: - The other parts

    static let contentTypes = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
        <Default Extension="xml" ContentType="application/xml"/>\
        <Override PartName="/word/document.xml" \
        ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>\
        <Override PartName="/word/styles.xml" \
        ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>\
        <Override PartName="/word/numbering.xml" \
        ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.numbering+xml"/>\
        <Override PartName="/docProps/core.xml" \
        ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>\
        </Types>
        """

    static let packageRelationships = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        <Relationship Id="rId1" \
        Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" \
        Target="word/document.xml"/>\
        <Relationship Id="rId2" \
        Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" \
        Target="docProps/core.xml"/>\
        </Relationships>
        """

    static let documentRelationships = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        <Relationship Id="rId1" \
        Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>\
        <Relationship Id="rId2" \
        Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/numbering" Target="numbering.xml"/>\
        </Relationships>
        """

    static func coreProperties(title: String, now: Date) -> String {
        let stamp = ISO8601DateFormatter().string(from: now)
        return """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <cp:coreProperties \
            xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" \
            xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" \
            xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">\
            <dc:title>\(escape(title))</dc:title><dc:creator>Parakeet</dc:creator>\
            <dcterms:created xsi:type="dcterms:W3CDTF">\(stamp)</dcterms:created>\
            <dcterms:modified xsi:type="dcterms:W3CDTF">\(stamp)</dcterms:modified>\
            </cp:coreProperties>
            """
    }

    static let styles = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">\
        <w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii="Helvetica Neue" w:hAnsi="Helvetica Neue" \
        w:cs="Helvetica Neue"/><w:sz w:val="22"/><w:szCs w:val="22"/><w:color w:val="1A1A1A"/></w:rPr></w:rPrDefault>\
        <w:pPrDefault><w:pPr><w:spacing w:after="140" w:line="276" w:lineRule="auto"/></w:pPr></w:pPrDefault>\
        </w:docDefaults>\
        <w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/></w:style>\
        <w:style w:type="paragraph" w:styleId="Title"><w:name w:val="Title"/><w:basedOn w:val="Normal"/>\
        <w:next w:val="Normal"/><w:pPr><w:spacing w:after="120"/></w:pPr><w:rPr><w:b/><w:sz w:val="40"/>\
        <w:szCs w:val="40"/></w:rPr></w:style>\
        <w:style w:type="paragraph" w:styleId="Heading1"><w:name w:val="heading 1"/><w:basedOn w:val="Normal"/>\
        <w:next w:val="Normal"/><w:pPr><w:keepNext/><w:spacing w:before="240" w:after="80"/><w:outlineLvl w:val="0"/>\
        </w:pPr><w:rPr><w:b/><w:sz w:val="30"/><w:szCs w:val="30"/></w:rPr></w:style>\
        <w:style w:type="paragraph" w:styleId="Heading2"><w:name w:val="heading 2"/><w:basedOn w:val="Normal"/>\
        <w:next w:val="Normal"/><w:pPr><w:keepNext/><w:spacing w:before="200" w:after="60"/><w:outlineLvl w:val="1"/>\
        </w:pPr><w:rPr><w:b/><w:sz w:val="25"/><w:szCs w:val="25"/></w:rPr></w:style>\
        <w:style w:type="paragraph" w:styleId="Metadata"><w:name w:val="Metadata"/><w:basedOn w:val="Normal"/>\
        <w:pPr><w:spacing w:after="20"/></w:pPr><w:rPr><w:color w:val="6B6B6B"/><w:sz w:val="19"/><w:szCs w:val="19"/>\
        </w:rPr></w:style>\
        <w:style w:type="paragraph" w:styleId="Speaker"><w:name w:val="Speaker"/><w:basedOn w:val="Normal"/>\
        <w:next w:val="Normal"/><w:pPr><w:keepNext/><w:spacing w:before="120" w:after="20"/></w:pPr>\
        <w:rPr><w:sz w:val="20"/><w:szCs w:val="20"/></w:rPr></w:style>\
        <w:style w:type="paragraph" w:styleId="ListParagraph"><w:name w:val="List Paragraph"/>\
        <w:basedOn w:val="Normal"/><w:pPr><w:spacing w:after="60"/><w:ind w:left="720"/></w:pPr></w:style>\
        </w:styles>
        """

    /// One bullet list definition with Word's nine levels; level 0 is the layout bullets always had, each deeper
    /// level a quarter inch further in.
    static let numbering: String = {
        let levels = (0...8).map { level in
            "<w:lvl w:ilvl=\"\(level)\"><w:start w:val=\"1\"/><w:numFmt w:val=\"bullet\"/><w:lvlText w:val=\"•\"/>"
                + "<w:lvlJc w:val=\"left\"/><w:pPr><w:ind w:left=\"\(720 + 360 * level)\" w:hanging=\"360\"/></w:pPr>"
                + "</w:lvl>"
        }.joined()
        return """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <w:numbering xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">\
            <w:abstractNum w:abstractNumId="0"><w:multiLevelType w:val="hybridMultilevel"/>\(levels)</w:abstractNum>\
            <w:num w:numId="1"><w:abstractNumId w:val="0"/></w:num>\
            </w:numbering>
            """
    }()
}
