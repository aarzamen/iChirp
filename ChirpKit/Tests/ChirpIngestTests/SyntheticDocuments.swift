import CoreGraphics
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
