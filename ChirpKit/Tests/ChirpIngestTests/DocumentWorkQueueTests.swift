import ChirpCore
import Synchronization
import XCTest

@testable import ChirpIngest

/// Review R2-7: document parsing blocks its thread, so it runs on the ingest document queue, never on Swift's small
/// cooperative pool, and it stops between parts when the import is cancelled. Synthetic documents only.
final class DocumentWorkQueueTests: XCTestCase {
    /// The label of the dedicated queue (`BlockingWork.queueLabel`).
    private static let documentQueueLabel = "com.aarzamen.ichirp.ingest.documents"
    private var directory: URL!

    override func setUpWithError() throws {
        directory = try makeTemporaryDirectory()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private static func currentQueueLabel() -> String {
        String(cString: __dispatch_queue_get_label(nil))
    }

    /// The reader's progress reports come from the thread that parses, which is the document queue.
    func testTextDocumentsAreParsedOnTheDocumentQueue() async throws {
        let extractor = DocumentTextExtractor(recognizer: FakeRecognizer(text: ""))
        let cases: [(String, Data, DocumentFormat)] = [
            ("memo.txt", Data("Synthetic memo text.".utf8), .plainText),
            ("page.html", Data("<p>Synthetic page</p>".utf8), .html),
            ("handout.docx", SyntheticDOCX.make(paragraphs: [["Synthetic handout."]]), .docx),
            ("note.rtf", Data(#"{\rtf1\ansi Synthetic note.\par}"#.utf8), .rtf),
        ]
        for (name, data, format) in cases {
            let url = directory.appendingPathComponent(name)
            try data.write(to: url)
            let labels = Mutex<[String]>([])
            _ = try await extractor.extract(from: url, format: format) { _, _ in
                labels.withLock { $0.append(Self.currentQueueLabel()) }
            }
            XCTAssertEqual(Set(labels.withLock { $0 }), [Self.documentQueueLabel], name)
        }
    }

    func testBlockingWorkRunsOnTheDocumentQueueAndSeesCancellation() async throws {
        let label = try await BlockingWork.run { _ in Self.currentQueueLabel() }
        XCTAssertEqual(label, Self.documentQueueLabel)
        XCTAssertEqual(BlockingWork.queueLabel, Self.documentQueueLabel)

        // Deterministic: the work waits until the test has cancelled the task, then reads the check once.
        let cancelled = DispatchSemaphore(value: 0)
        let task = Task {
            try await BlockingWork.run { isCancelled in
                cancelled.wait()
                return isCancelled()
            }
        }
        task.cancel()
        cancelled.signal()
        let sawCancellation = try await task.value
        XCTAssertTrue(sawCancellation)
    }

    /// A long Word body stops parsing once the import is cancelled, instead of running to the end.
    func testDOCXParsingStopsWhenCancelled() throws {
        let paragraphs = (0..<5_000).map { ["Synthetic paragraph \($0) of a long handout."] }
        let data = SyntheticDOCX.make(paragraphs: paragraphs)
        let checks = Mutex(0)
        XCTAssertThrowsError(
            try DOCXReader.read(data) {
                checks.withLock {
                    $0 += 1
                    return $0 > 3
                }
            }
        ) { error in
            XCTAssertTrue(error is CancellationError, "got \(error)")
        }
        XCTAssertLessThan(checks.withLock { $0 }, 50, "parsing stopped soon after the first positive check")
    }

    /// Cancelling between the reading steps of a text, HTML or RTF document throws `CancellationError`.
    func testTextReadersStopWhenCancelled() {
        let cancelled: () -> Bool = { true }
        let text = Data("Synthetic.".utf8)
        XCTAssertThrowsError(try PlainTextReader.read(text, format: .plainText, isCancelled: cancelled)) {
            XCTAssertTrue($0 is CancellationError)
        }
        XCTAssertThrowsError(try HTMLTextReader.read(Data("<p>Synthetic</p>".utf8), isCancelled: cancelled)) {
            XCTAssertTrue($0 is CancellationError)
        }
        XCTAssertThrowsError(try RichTextReader.read(Data(#"{\rtf1 Synthetic.}"#.utf8), isCancelled: cancelled)) {
            XCTAssertTrue($0 is CancellationError)
        }
    }
}
