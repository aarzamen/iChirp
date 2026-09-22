import ChirpCore
import ChirpIngest
import XCTest

@testable import iChirp

/// M5 screen logic: document meta lines, covers, paragraphs, and the Paste a link sheet's copy.
final class IngestScreenLogicTests: XCTestCase {
    func testDocumentMetaLine() {
        var pdf = Transcription(sourceType: .document, fileName: "a.pdf", status: .completed)
        pdf.documentFormat = .pdf
        pdf.documentPages = [
            DocumentPage(number: 1, text: "a", method: .textLayer),
            DocumentPage(number: 2, text: "b", method: .ocr),
            DocumentPage(number: 3, text: "", method: .empty),
        ]
        XCTAssertEqual(DocumentRow.meta(for: pdf), "PDF · 3 pages · 1 read with OCR")
        pdf.documentPages = [DocumentPage(number: 1, text: "b", method: .ocr)]
        XCTAssertEqual(DocumentRow.meta(for: pdf), "PDF · 1 page · read with OCR")

        var word = Transcription(sourceType: .document, fileName: "b.docx", status: .completed)
        word.documentFormat = .docx
        word.rawTranscript = "one two three"
        XCTAssertEqual(DocumentRow.meta(for: word), "Word · 3 words")
    }

    func testCoversAndParagraphs() {
        XCTAssertEqual(DocumentCover.badge(for: .markdown), "MD")
        XCTAssertEqual(DocumentCover.badge(for: nil), "DOC")
        XCTAssertEqual(DocumentScreen.paragraphs(of: "a\n\n\n\nb\nc\n\n  "), ["a", "b\nc"])
        XCTAssertEqual(DocumentScreen.exportFormats.map(\.rawValue), ["txt", "markdown", "json"], "no SRT/VTT")
    }

    func testPasteSheetCopyNamesWhatLeavesThePhone() {
        XCTAssertTrue(
            PasteLinkSheet.privacyNote(
                for: .youtube(videoID: "AAAAAAAAAAA", url: URL(string: "https://youtu.be/AAAAAAAAAAA")!)
            ).contains("YouTube"))
        XCTAssertTrue(
            PasteLinkSheet.privacyNote(for: .directMedia(URL(string: "https://a.example/b.mp3")!)).hasPrefix(
                "Only the link"))
        XCTAssertEqual(PasteLinkSheet.symbol(for: .unsupported(.empty)), "exclamationmark.triangle")
    }
}
