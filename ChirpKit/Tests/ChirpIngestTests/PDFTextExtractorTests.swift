import ChirpCore
import CoreGraphics
import Synchronization
import XCTest

@testable import ChirpIngest

/// Stands in for Vision in the deterministic tests: answers each call with the next of `texts` (the last one
/// repeats) and counts calls.
final class FakeRecognizer: PageTextRecognizing {
    private let calls = Mutex(0)
    let texts: [String]

    init(text: String) {
        texts = [text]
    }

    init(texts: [String]) {
        self.texts = texts
    }

    var callCount: Int { calls.withLock { $0 } }

    func recognizeText(in image: CGImage) async throws -> String {
        let index = calls.withLock { count -> Int in
            defer { count += 1 }
            return count
        }
        return texts[min(index, texts.count - 1)]
    }
}

/// PDFs generated at test time (text layer, image-only, blank, protected); nothing real.
final class PDFTextExtractorTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = try makeTemporaryDirectory()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func write(_ data: Data, as name: String = "handout.pdf") throws -> URL {
        let url = directory.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    func testTextPagesUseTheTextLayerAndImagePagesUseOCR() async throws {
        let url = try write(
            SyntheticPDF.make(
                [
                    .text(["Synthetic handout, page one.", "Nothing here is real patient data."]),
                    .image(["SCANNED PAGE TWO"]),
                    .blank,
                ], title: "A Synthetic Handout"))
        let recognizer = FakeRecognizer(texts: ["Scanned page two, recognized.", "  "])
        let progress = Mutex<[(Int, Int)]>([])
        let result = try await DocumentTextExtractor(recognizer: recognizer).extract(from: url, format: .pdf) {
            done, total in progress.withLock { $0.append((done, total)) }
        }

        let pages = try XCTUnwrap(result.pages)
        XCTAssertEqual(pages.map(\.number), [1, 2, 3])
        XCTAssertEqual(pages.map(\.method), [.textLayer, .ocr, .empty])
        XCTAssertTrue(pages[0].text.contains("Synthetic handout, page one."), pages[0].text)
        XCTAssertEqual(pages[1].text, "Scanned page two, recognized.")
        XCTAssertEqual(pages[2].text, "")
        XCTAssertEqual(recognizer.callCount, 2, "only the pages without a text layer are rendered and recognized")
        XCTAssertTrue(result.text.hasPrefix("Synthetic handout, page one."))
        XCTAssertTrue(result.text.hasSuffix("\n\nScanned page two, recognized."))
        XCTAssertEqual(result.title, "A Synthetic Handout")
        XCTAssertEqual(progress.withLock { $0.last?.0 }, 3)
        XCTAssertEqual(progress.withLock { $0.first?.0 }, 0)
    }

    /// The real on-device recognizer (Vision) reads a page that has no text layer.
    func testVisionReadsAnImageOnlyPage() async throws {
        let url = try write(SyntheticPDF.make([.image(["PARAKEET READS SCANS", "SYNTHETIC PAGE"])]))
        let result = try await DocumentTextExtractor().extract(from: url, format: .pdf) { _, _ in }
        XCTAssertEqual(result.pages?.first?.method, .ocr)
        let text = result.text.uppercased()
        XCTAssertTrue(text.contains("PARAKEET") && text.contains("SCANS"), "recognized: \(result.text)")
    }

    func testRendersPagesForOCRAtReadableSize() throws {
        let url = try write(SyntheticPDF.make([.blank]))
        let document = try XCTUnwrap(PDFDocumentLoader.open(url))
        let image = try XCTUnwrap(PDFTextExtractor.render(try XCTUnwrap(document.page(at: 0))))
        XCTAssertEqual(max(image.width, image.height), Int(PDFTextExtractor.renderLongSide))
    }

    func testPasswordProtectedPDFIsReported() async throws {
        let url = try write(SyntheticPDF.make([.text(["Secret synthetic text"])], password: "synthetic"))
        do {
            _ = try await DocumentTextExtractor(recognizer: FakeRecognizer(text: "")).extract(from: url, format: .pdf) {
                _, _ in
            }
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? DocumentExtractionError, .passwordProtected)
        }
    }

    func testNotAPDFAndEmptyPDFFailClearly() async throws {
        let garbage = try write(Data("this is not a pdf".utf8), as: "fake.pdf")
        do {
            _ = try await DocumentTextExtractor(recognizer: FakeRecognizer(text: "")).extract(
                from: garbage, format: .pdf
            ) { _, _ in }
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? DocumentExtractionError, .unreadable(.pdf))
            XCTAssertTrue((error as? DocumentExtractionError)?.errorDescription?.contains("PDF") == true)
        }
        let blank = try write(SyntheticPDF.make([.blank, .blank]), as: "blank.pdf")
        do {
            _ = try await DocumentTextExtractor(recognizer: FakeRecognizer(text: "  ")).extract(
                from: blank, format: .pdf
            ) { _, _ in }
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? DocumentExtractionError, .noText(.pdf))
        }
    }

    func testCancellationStopsBetweenPages() async throws {
        let url = try write(SyntheticPDF.make(Array(repeating: .text(["Synthetic page text for cancel."]), count: 5)))
        let task = Task {
            try await DocumentTextExtractor(recognizer: FakeRecognizer(text: "")).extract(from: url, format: .pdf) {
                _, _ in
            }
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testPlausibleTitles() {
        XCTAssertEqual(
            DocumentTextExtractor.plausibleTitle("  Quarterly Synthetic Review "), "Quarterly Synthetic Review")
        XCTAssertNil(DocumentTextExtractor.plausibleTitle("Microsoft Word - notes.docx"))
        XCTAssertNil(DocumentTextExtractor.plausibleTitle("scan0001.pdf"))
        XCTAssertNil(DocumentTextExtractor.plausibleTitle("Untitled"))
        XCTAssertNil(DocumentTextExtractor.plausibleTitle(""))
    }

    func testTidyCollapsesBlankRunsAndTrailingSpaces() {
        XCTAssertEqual(DocumentTextExtractor.tidy("a  \r\n\r\n\n\nb\t\n"), "a\n\nb")
    }
}

import PDFKit

enum PDFDocumentLoader {
    static func open(_ url: URL) -> PDFDocument? { PDFDocument(url: url) }
}
