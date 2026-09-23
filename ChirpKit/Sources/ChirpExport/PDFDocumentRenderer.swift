// Plan 022 Step 6 (plan 017 item 1): a real multi-page PDF. Semantics from MacParakeet (GPL-3.0)
// `Sources/MacParakeetCore/Services/ExportService.swift` @ bbae9e0e (`exportToPDF`: US Letter, a Core Graphics PDF
// context, the text laid out and drawn page after page, explicit colors so dark mode never makes text invisible).
// Changes: Core Text (`CTFramesetter`) instead of AppKit's `NSLayoutManager`, so it runs on iOS and in tests on the
// Mac; pages break between lines (never inside one); every page carries "title · Page k of N".

import CoreGraphics
import CoreText
import Foundation

public enum PDFExportError: Error, Equatable, LocalizedError {
    case contextUnavailable
    /// A single line could not fit on a page (never expected with the fixed sizes used here).
    case layoutStalled

    public var errorDescription: String? {
        switch self {
        case .contextUnavailable: "The PDF could not be created."
        case .layoutStalled: "The PDF could not lay out this text."
        }
    }
}

/// Renders an `ExportDocument` into PDF data: US Letter, 0.75-inch margins, as many pages as the text needs.
public struct PDFDocumentRenderer: Sendable {
    public static let pageSize = CGSize(width: 612, height: 792)
    public static let margin: CGFloat = 54
    static let footerHeight: CGFloat = 22

    public init() {}

    public func render(_ document: ExportDocument) throws -> Data {
        let text = Self.attributedText(for: document)
        let framesetter = CTFramesetterCreateWithAttributedString(text)
        let bodyRect = CGRect(
            x: Self.margin, y: Self.margin + Self.footerHeight, width: Self.pageSize.width - 2 * Self.margin,
            height: Self.pageSize.height - 2 * Self.margin - Self.footerHeight)
        let path = CGPath(rect: bodyRect, transform: nil)

        // Pass 1: where each page starts, so every footer can say "of N".
        var pages: [CFRange] = []
        var location = 0
        let length = text.length
        let string = text.string as NSString
        while location < length {
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: location, length: 0), path, nil)
            let visible = CTFrameGetVisibleStringRange(frame)
            guard visible.length > 0 else { throw PDFExportError.layoutStalled }
            var end = location + visible.length
            // A heading or speaker line never ends a page alone: it moves to the next page with its paragraph.
            if end < length {
                let last = string.paragraphRange(for: NSRange(location: end - 1, length: 0))
                if last.location > location,
                    text.attribute(Self.keepWithNext, at: last.location, effectiveRange: nil) != nil
                {
                    end = last.location
                }
            }
            pages.append(CFRange(location: location, length: end - location))
            location = end
        }
        if pages.isEmpty { pages.append(CFRange(location: 0, length: 0)) }

        // Pass 2: draw.
        let data = NSMutableData()
        var mediaBox = CGRect(origin: .zero, size: Self.pageSize)
        let info: [CFString: Any] = [
            kCGPDFContextTitle: document.title,
            kCGPDFContextCreator: "Parakeet",
        ]
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
            let context = CGContext(consumer: consumer, mediaBox: &mediaBox, info as CFDictionary)
        else { throw PDFExportError.contextUnavailable }
        for (index, range) in pages.enumerated() {
            context.beginPDFPage(nil)
            context.setFillColor(Self.white)
            context.fill(mediaBox)
            let frame = CTFramesetterCreateFrame(framesetter, range, path, nil)
            CTFrameDraw(frame, context)
            drawFooter("\(document.title) · Page \(index + 1) of \(pages.count)", in: context)
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }

    private func drawFooter(_ text: String, in context: CGContext) {
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: text, attributes: Self.attributes(size: 8.5, weight: .regular, color: Self.gray))
        )
        context.textMatrix = .identity
        context.textPosition = CGPoint(x: Self.margin, y: Self.margin)
        CTLineDraw(line, context)
    }

    // MARK: - Text

    enum Weight { case regular, bold }

    /// Marks a paragraph (a heading, a speaker line) that must stay on the page of the paragraph after it.
    static let keepWithNext = NSAttributedString.Key("ChirpKeepWithNext")

    /// `attributes` plus the keep-with-next mark.
    static func kept(_ attributes: [NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any] {
        attributes.merging([keepWithNext: true]) { first, _ in first }
    }

    static let ink = CGColor(red: 0.10, green: 0.10, blue: 0.10, alpha: 1)
    static let gray = CGColor(red: 0.42, green: 0.42, blue: 0.42, alpha: 1)
    static let accent = CGColor(red: 0.745, green: 0.306, blue: 0.149, alpha: 1)  // accent-ink #BE4E26
    static let white = CGColor(red: 1, green: 1, blue: 1, alpha: 1)

    static func font(size: CGFloat, weight: Weight, monospaced: Bool = false) -> CTFont {
        if monospaced {
            return CTFontCreateUIFontForLanguage(.userFixedPitch, size, nil)
                ?? CTFontCreateWithName("Menlo" as CFString, size, nil)
        }
        let type: CTFontUIFontType = weight == .bold ? .emphasizedSystem : .system
        return CTFontCreateUIFontForLanguage(type, size, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
    }

    static func attributes(
        size: CGFloat, weight: Weight, color: CGColor, monospaced: Bool = false, spacingBefore: CGFloat = 0,
        spacingAfter: CGFloat = 0, headIndent: CGFloat = 0, lineSpacing: CGFloat = 0
    ) -> [NSAttributedString.Key: Any] {
        let specifiers: [CTParagraphStyleSpecifier] = [
            .paragraphSpacingBefore, .paragraphSpacing, .headIndent, .lineSpacingAdjustment,
        ]
        let values: [CGFloat] = [spacingBefore, spacingAfter, headIndent, lineSpacing]
        // A list item's text starts at its hanging indent: one tab stop there.
        let tabs = headIndent > 0 ? [CTTextTabCreate(.left, Double(headIndent), nil)] as CFArray : [] as CFArray
        let style = values.withUnsafeBufferPointer { buffer in
            withUnsafePointer(to: tabs) { tabsPointer in
                var settings = specifiers.indices.map { index in
                    CTParagraphStyleSetting(
                        spec: specifiers[index], valueSize: MemoryLayout<CGFloat>.size,
                        value: UnsafeRawPointer(buffer.baseAddress! + index))
                }
                settings.append(
                    CTParagraphStyleSetting(
                        spec: .tabStops, valueSize: MemoryLayout<CFArray>.size, value: UnsafeRawPointer(tabsPointer)))
                return CTParagraphStyleCreate(settings, settings.count)
            }
        }
        return [
            NSAttributedString.Key(kCTFontAttributeName as String): font(
                size: size, weight: weight, monospaced: monospaced),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
            NSAttributedString.Key(kCTParagraphStyleAttributeName as String): style,
        ]
    }

    /// The whole document as one attributed string (Core Text lays it out and breaks the pages).
    static func attributedText(for document: ExportDocument) -> NSAttributedString {
        let text = NSMutableAttributedString()
        func append(_ string: String, _ attributes: [NSAttributedString.Key: Any]) {
            text.append(NSAttributedString(string: string, attributes: attributes))
        }
        append(document.title + "\n", attributes(size: 20, weight: .bold, color: ink, spacingAfter: 6))
        for line in document.metadata {
            let label = attributes(size: 9.5, weight: .bold, color: gray)
            let value = attributes(size: 9.5, weight: .regular, color: gray, spacingAfter: 1)
            append("\(line.label): ", label)
            append(line.value + "\n", value)
        }
        if !document.metadata.isEmpty {
            append("\n", attributes(size: 6, weight: .regular, color: gray))
        }
        let body = attributes(size: 11, weight: .regular, color: ink, spacingAfter: 7, lineSpacing: 1.5)
        for block in document.blocks {
            switch block {
            case .heading(let heading, let level):
                append(
                    heading + "\n",
                    kept(
                        attributes(
                            size: level <= 1 ? 15 : 12.5, weight: .bold, color: ink, spacingBefore: 8, spacingAfter: 4))
                )
            case .paragraph(let paragraph):
                append(Self.safe(paragraph) + "\n", body)
            case .turn(let speaker, let timestamp, let words):
                if speaker != nil || timestamp != nil {
                    if let speaker {
                        append(speaker, kept(attributes(size: 10, weight: .bold, color: accent, spacingBefore: 4)))
                        append(timestamp == nil ? "\n" : "  ", attributes(size: 10, weight: .bold, color: accent))
                    }
                    if let timestamp {
                        append(
                            timestamp + "\n",
                            kept(
                                attributes(
                                    size: 9, weight: .regular, color: gray, monospaced: true, spacingBefore: 4)))
                    }
                }
                append(Self.safe(words) + "\n", body)
            case .bullet(let item):
                append(
                    "•\t" + Self.safe(item) + "\n",
                    attributes(size: 11, weight: .regular, color: ink, spacingAfter: 3, headIndent: 18))
            case .numbered(let number, let item):
                append(
                    "\(number).\t" + Self.safe(item) + "\n",
                    attributes(size: 11, weight: .regular, color: ink, spacingAfter: 3, headIndent: 22))
            }
        }
        if let footer = document.footer {
            append("\n" + footer + "\n", attributes(size: 8.5, weight: .regular, color: gray, spacingBefore: 8))
        }
        return text
    }

    /// Keeps a paragraph's own line breaks as line breaks inside it.
    private static func safe(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\u{2028}")
    }
}
