import CoreGraphics
@testable import ChirpIngest
import CoreText
import Foundation

/// Builds test documents at test time: synthetic text only, no real documents in the repo.
enum SyntheticPDF {
    enum Page {
        /// Real text drawn with CoreText: the PDF has a text layer.
        case text([String])
        /// The same text rendered into a bitmap and placed as an image: no text layer, like a scan.
        case image([String])
        /// Nothing on the page.
        case blank
    }

    static let pageBox = CGRect(x: 0, y: 0, width: 612, height: 792)

    static func make(_ pages: [Page], title: String? = nil, password: String? = nil) -> Data {
        let data = NSMutableData()
        var mediaBox = pageBox
        var info: [CFString: Any] = [:]
        if let title { info[kCGPDFContextTitle] = title }
        if let password {
            info[kCGPDFContextUserPassword] = password
            info[kCGPDFContextOwnerPassword] = password
        }
        let consumer = CGDataConsumer(data: data as CFMutableData)!
        let context = CGContext(consumer: consumer, mediaBox: &mediaBox, info as CFDictionary)!
        for page in pages {
            context.beginPDFPage(nil)
            switch page {
            case .text(let lines):
                draw(lines, in: context, fontSize: 18, origin: CGPoint(x: 72, y: 700), lineHeight: 28)
            case .image(let lines):
                if let image = bitmap(of: lines) {
                    context.draw(image, in: pageBox)
                }
            case .blank:
                break
            }
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }

    /// `lines` drawn black on white at twice the page size, large enough for text recognition.
    static func bitmap(of lines: [String]) -> CGImage? {
        let width = Int(pageBox.width * 2)
        let height = Int(pageBox.height * 2)
        guard
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else {
            return nil
        }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        draw(lines, in: context, fontSize: 64, origin: CGPoint(x: 120, y: CGFloat(height) - 220), lineHeight: 110)
        return context.makeImage()
    }

    private static func draw(
        _ lines: [String], in context: CGContext, fontSize: CGFloat, origin: CGPoint, lineHeight: CGFloat
    ) {
        let font = CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
        let black = CGColor(red: 0, green: 0, blue: 0, alpha: 1)
        for (index, line) in lines.enumerated() {
            let attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): black,
            ]
            let ctLine = CTLineCreateWithAttributedString(NSAttributedString(string: line, attributes: attributes))
            context.textPosition = CGPoint(x: origin.x, y: origin.y - CGFloat(index) * lineHeight)
            CTLineDraw(ctLine, context)
        }
    }
}

/// A minimal ZIP writer for tests (stored or deflated entries), so DOCX files can be generated at test time.
enum SyntheticZip {
    static func make(_ files: [(name: String, data: Data)], deflate: Bool = true) -> Data {
        var archive = Data()
        var directory = Data()
        for file in files {
            let crc = CRC32.checksum(file.data)
            let compressed: Data
            let method: UInt16
            if deflate, let packed = try? (file.data as NSData).compressed(using: .zlib) as Data {
                compressed = packed
                method = 8
            } else {
                compressed = file.data
                method = 0
            }
            let offset = UInt32(archive.count)
            let name = Data(file.name.utf8)
            var local = Data()
            local.append(le32(0x0403_4b50))
            local.append(le16(20))
            local.append(le16(0))
            local.append(le16(method))
            local.append(le16(0))
            local.append(le16(0))
            local.append(le32(crc))
            local.append(le32(UInt32(compressed.count)))
            local.append(le32(UInt32(file.data.count)))
            local.append(le16(UInt16(name.count)))
            local.append(le16(0))
            local.append(name)
            archive.append(local)
            archive.append(compressed)

            var central = Data()
            central.append(le32(0x0201_4b50))
            central.append(le16(20))
            central.append(le16(20))
            central.append(le16(0))
            central.append(le16(method))
            central.append(le16(0))
            central.append(le16(0))
            central.append(le32(crc))
            central.append(le32(UInt32(compressed.count)))
            central.append(le32(UInt32(file.data.count)))
            central.append(le16(UInt16(name.count)))
            central.append(le16(0))
            central.append(le16(0))
            central.append(le16(0))
            central.append(le16(0))
            central.append(le32(0))
            central.append(le32(offset))
            central.append(name)
            directory.append(central)
        }
        let directoryOffset = UInt32(archive.count)
        archive.append(directory)
        archive.append(le32(0x0605_4b50))
        archive.append(le16(0))
        archive.append(le16(0))
        archive.append(le16(UInt16(files.count)))
        archive.append(le16(UInt16(files.count)))
        archive.append(le32(UInt32(directory.count)))
        archive.append(le32(directoryOffset))
        archive.append(le16(0))
        return archive
    }

    private static func le16(_ value: UInt16) -> Data {
        Data([UInt8(value & 0xFF), UInt8(value >> 8)])
    }

    private static func le32(_ value: UInt32) -> Data {
        Data((0..<4).map { UInt8((value >> (8 * $0)) & 0xFF) })
    }
}

/// A Word document with the given paragraphs (each a list of runs), generated at test time.
enum SyntheticDOCX {
    static func make(paragraphs: [[String]], title: String? = nil, deflate: Bool = true) -> Data {
        let body = paragraphs.map { runs in
            "<w:p><w:pPr><w:pStyle w:val=\"Normal\"/></w:pPr>"
                + runs.map { "<w:r><w:t xml:space=\"preserve\">\(escape($0))</w:t></w:r>" }.joined() + "</w:p>"
        }.joined()
        let document = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>\(body)\
            <w:p><w:r><w:delText>deleted words</w:delText></w:r><w:r><w:instrText>PAGE</w:instrText></w:r></w:p>\
            <w:p><w:r><w:t>Tab</w:t><w:tab/><w:t>and</w:t><w:br/><w:t>break</w:t></w:r></w:p>\
            </w:body></w:document>
            """
        var files: [(String, Data)] = [
            ("[Content_Types].xml", Data(#"<?xml version="1.0"?><Types/>"#.utf8)),
            ("word/document.xml", Data(document.utf8)),
        ]
        if let title {
            let core = """
                <?xml version="1.0" encoding="UTF-8"?>
                <cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" \
                xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>\(escape(title))</dc:title></cp:coreProperties>
                """
            files.append(("docProps/core.xml", Data(core.utf8)))
        }
        return SyntheticZip.make(files, deflate: deflate)
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
