import CoreGraphics
import Synchronization
import XCTest

@testable import ChirpIngest

/// Review R2-16: every document Vision detects on a page is kept (in reading order), and a page where the documents
/// request reads nothing falls back to the line-by-line request. Vision is replaced by closures here.
final class PageTextRecognizerTests: XCTestCase {
    private typealias Block = VisionPageTextRecognizer.RecognizedDocument

    func testEveryDetectedDocumentIsKeptTopToBottomThenLeftToRight() {
        // Vision's normalized coordinates: origin bottom-left.
        let blocks = [
            Block(box: CGRect(x: 0.55, y: 0.1, width: 0.4, height: 0.3), paragraphs: ["Slip C, lower right"], text: ""),
            Block(box: CGRect(x: 0.55, y: 0.5, width: 0.4, height: 0.4), paragraphs: ["Slip B, right"], text: ""),
            Block(box: CGRect(x: 0.05, y: 0.5, width: 0.4, height: 0.4), paragraphs: ["Slip A, left", "  "], text: ""),
            Block(box: CGRect(x: 0.05, y: 0.1, width: 0.4, height: 0.2), paragraphs: [], text: "Slip D as one text"),
        ]
        XCTAssertEqual(
            VisionPageTextRecognizer.joined(blocks),
            "Slip A, left\n\nSlip B, right\n\nSlip C, lower right\n\nSlip D as one text")
    }

    func testAPageTheDocumentsRequestReadsAsEmptyFallsBackToLines() async throws {
        let empty = [Block(box: CGRect(x: 0, y: 0, width: 1, height: 1), paragraphs: [], text: "")]
        let text = try await VisionPageTextRecognizer.recognize(
            documents: { empty }, lines: { ["Synthetic small line one", "line two"] })
        XCTAssertEqual(text, "Synthetic small line one\nline two")
    }

    func testAFailedDocumentsRequestFallsBackToLines() async throws {
        struct Unsupported: Error {}
        let text = try await VisionPageTextRecognizer.recognize(
            documents: { throw Unsupported() }, lines: { ["Synthetic fallback line"] })
        XCTAssertEqual(text, "Synthetic fallback line")
    }

    func testLinesAreNotRequestedWhenTheDocumentsHaveText() async throws {
        let linesCalls = Mutex(0)
        let blocks = [Block(box: CGRect(x: 0, y: 0, width: 1, height: 1), paragraphs: ["Synthetic page"], text: "")]
        let text = try await VisionPageTextRecognizer.recognize(
            documents: { blocks },
            lines: {
                linesCalls.withLock { $0 += 1 }
                return []
            })
        XCTAssertEqual(text, "Synthetic page")
        XCTAssertEqual(linesCalls.withLock { $0 }, 0)
    }
}
