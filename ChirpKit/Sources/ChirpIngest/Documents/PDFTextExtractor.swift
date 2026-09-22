import ChirpCore
import CoreGraphics
import Foundation
import PDFKit

/// A PDF's text, page by page: the PDF's own text layer (PDFKit) when a page has one, otherwise the page rendered to
/// an image and read with on-device text recognition (`PageTextRecognizing`, Vision). Nothing leaves the phone.
struct PDFTextExtractor: Sendable {
    /// A page whose text layer has fewer visible characters than this is also read with OCR (a scan often carries
    /// only a page number or a stamp as text); the longer result wins.
    static let minimumTextLayerCharacters = 20
    /// The longer side of a page rendered for OCR, in pixels (about 250 dpi for a Letter page).
    static let renderLongSide: CGFloat = 2_200

    let recognizer: any PageTextRecognizing
    private let logger = Log.logger("documents")

    func extract(from url: URL, progress: @escaping @Sendable (Int, Int) -> Void) async throws -> ExtractedDocument {
        guard let document = PDFDocument(url: url) else {
            throw DocumentExtractionError.unreadable(.pdf)
        }
        if document.isLocked {
            throw DocumentExtractionError.passwordProtected
        }
        let count = document.pageCount
        guard count > 0 else { throw DocumentExtractionError.noText(.pdf) }
        progress(0, count)

        var pages: [DocumentPage] = []
        pages.reserveCapacity(count)
        var ocrPages = 0
        for index in 0..<count {
            try Task.checkCancellation()
            guard let page = document.page(at: index) else { continue }
            let layerText = DocumentTextExtractor.tidy(page.string ?? "")
            var chosen = DocumentPage(
                number: index + 1, text: layerText, method: layerText.isEmpty ? .empty : .textLayer)
            if Self.visibleCharacterCount(layerText) < Self.minimumTextLayerCharacters,
                let image = Self.render(page)
            {
                let recognized = DocumentTextExtractor.tidy(try await recognizer.recognizeText(in: image))
                if Self.visibleCharacterCount(recognized) > Self.visibleCharacterCount(layerText) {
                    chosen = DocumentPage(number: index + 1, text: recognized, method: .ocr)
                    ocrPages += 1
                }
            }
            pages.append(chosen)
            progress(index + 1, count)
        }

        let text = pages.map(\.text).filter { !$0.isEmpty }.joined(separator: "\n\n")
        logger.info(
            "pdf_extracted pages=\(count, privacy: .public) ocr_pages=\(ocrPages, privacy: .public) chars=\(text.count, privacy: .public)"
        )
        guard !text.isEmpty else { throw DocumentExtractionError.noText(.pdf) }
        let title = DocumentTextExtractor.plausibleTitle(
            document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String)
        return ExtractedDocument(text: text, pages: pages, title: title)
    }

    static func visibleCharacterCount(_ text: String) -> Int {
        text.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.count
    }

    /// Renders `page` (its crop box, rotation applied) on white at about `renderLongSide` pixels.
    static func render(_ page: PDFPage) -> CGImage? {
        guard let pageRef = page.pageRef else { return nil }
        let box = pageRef.getBoxRect(.cropBox)
        guard box.width > 0, box.height > 0 else { return nil }
        let rotated = abs(pageRef.rotationAngle) % 180 == 90
        let pageSize = rotated ? CGSize(width: box.height, height: box.width) : box.size
        let scale = min(4, renderLongSide / max(pageSize.width, pageSize.height))
        let width = Int((pageSize.width * scale).rounded())
        let height = Int((pageSize.height * scale).rounded())
        guard
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else {
            return nil
        }
        let target = CGRect(x: 0, y: 0, width: width, height: height)
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(target)
        context.interpolationQuality = .high
        // Scale first, then let CoreGraphics map the crop box (with its rotation) into the page-sized rectangle.
        context.scaleBy(x: scale, y: scale)
        let transform = pageRef.getDrawingTransform(
            .cropBox, rect: CGRect(origin: .zero, size: pageSize), rotate: 0, preserveAspectRatio: true)
        context.concatenate(transform)
        context.drawPDFPage(pageRef)
        return context.makeImage()
    }
}
