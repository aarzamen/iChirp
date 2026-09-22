import ChirpCore
import ChirpIngest
import Foundation
import Synchronization
import XCTest

@testable import ChirpFeatures

/// Returns a canned extraction (or error), reporting two pages of progress; or waits until cancelled.
final class FakeExtractor: DocumentTextExtracting {
    enum Behavior: Sendable {
        case succeed(ExtractedDocument)
        case fail(DocumentExtractionError)
        case waitForCancel
    }

    private let state: Mutex<(behavior: Behavior, formats: [DocumentFormat])>
    let started = Signal()

    init(_ behavior: Behavior) {
        state = Mutex((behavior, []))
    }

    var formats: [DocumentFormat] { state.withLock { $0.formats } }

    func setBehavior(_ behavior: Behavior) {
        state.withLock { $0.behavior = behavior }
    }

    func extract(
        from url: URL, format: DocumentFormat, progress: @escaping @Sendable (Int, Int) -> Void
    ) async throws -> ExtractedDocument {
        let behavior = state.withLock { state -> Behavior in
            state.formats.append(format)
            return state.behavior
        }
        switch behavior {
        case .succeed(let document):
            progress(0, 2)
            progress(1, 2)
            progress(2, 2)
            return document
        case .fail(let error):
            throw error
        case .waitForCancel:
            started.fire()
            while !Task.isCancelled {
                await Task.yield()
            }
            throw CancellationError()
        }
    }
}

final class DocumentImportPipelineTests: XCTestCase {
    private var base: URL!
    private var paths: AppPaths!
    private var outside: URL!
    private let store = FakeStore()
    private let log = LinkProgressLog()

    static let extracted = ExtractedDocument(
        text: "Synthetic Handout Title\n\nThe first synthetic paragraph says nothing real.\n\nPage two text.",
        pages: [
            DocumentPage(
                number: 1, text: "Synthetic Handout Title\n\nThe first synthetic paragraph says nothing real.",
                method: .textLayer),
            DocumentPage(number: 2, text: "Page two text.", method: .ocr),
        ],
        title: "A Synthetic Handout")

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("DocumentImportPipelineTests-\(UUID().uuidString)", isDirectory: true)
        paths = AppPaths(root: base.appendingPathComponent("iChirp", isDirectory: true))
        outside = base.appendingPathComponent("Files", isDirectory: true)
        try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
    }

    private func makePipeline(_ extractor: FakeExtractor) -> DocumentImportPipeline {
        DocumentImportPipeline(paths: paths, store: store, extractor: extractor, onProgress: log.handler)
    }

    private func makeFile(_ name: String, bytes: Int = 512) throws -> URL {
        let url = outside.appendingPathComponent(name)
        try Data(repeating: 65, count: bytes).write(to: url)
        return url
    }

    func testImportCopiesTheFileAndInsertsAProcessingDocumentRow() async throws {
        let pipeline = makePipeline(FakeExtractor(.succeed(Self.extracted)))
        let file = try makeFile("Synthetic handout.PDF")
        let id = try await pipeline.importItem(from: file)

        let stored = await store.row(id)
        let row = try XCTUnwrap(stored)
        XCTAssertEqual(row.sourceType, .document)
        XCTAssertEqual(row.documentFormat, .pdf)
        XCTAssertEqual(row.status, .processing)
        XCTAssertEqual(row.fileName, "Synthetic handout.PDF")
        XCTAssertEqual(row.mediaRelativePath, "media/\(id.uuidString)/source.pdf")
        XCTAssertEqual(row.fileSizeBytes, 512)
        XCTAssertEqual(row.privacyClass, .personal)
        XCTAssertTrue(fileExists(file), "the person's file is copied, never moved")
        XCTAssertTrue(fileExists(paths.mediaDirectory(for: id).appendingPathComponent("source.pdf")))
    }

    func testProcessSavesTextPagesTitleAndSnippet() async throws {
        let extractor = FakeExtractor(.succeed(Self.extracted))
        let pipeline = makePipeline(extractor)
        let id = try await pipeline.importItem(from: try makeFile("handout.pdf"))
        let processed = await pipeline.process(id: id)
        let done = try XCTUnwrap(processed)

        XCTAssertEqual(done.status, .completed)
        XCTAssertEqual(done.rawTranscript, Self.extracted.text)
        XCTAssertEqual(done.displayText, Self.extracted.text, "templates read the document's text")
        XCTAssertNil(done.cleanTranscript)
        XCTAssertEqual(done.documentPages, Self.extracted.pages)
        XCTAssertEqual(done.ocrPageCount, 1)
        XCTAssertEqual(done.sourceTitle, "A Synthetic Handout")
        XCTAssertEqual(done.displayTitle, "A Synthetic Handout")
        XCTAssertFalse(done.derivedTitle?.isEmpty ?? true)
        XCTAssertNil(done.wordTimestamps)
        XCTAssertNil(done.durationMs)
        XCTAssertEqual(extractor.formats, [.pdf])
        XCTAssertEqual(Set(log.stages(for: id)), [.readingDocument])
        XCTAssertEqual(log.fractions(for: id).last, 1)
        XCTAssertTrue(fileExists(paths.mediaDirectory(for: id).appendingPathComponent("source.pdf")), "source kept")
    }

    func testUserEditsDuringExtractionSurvive() async throws {
        let extractor = FakeExtractor(.waitForCancel)
        let pipeline = makePipeline(extractor)
        let id = try await pipeline.importItem(from: try makeFile("handout.docx"))
        extractor.setBehavior(.succeed(Self.extracted))
        _ = try await store.updatePrivacyClass(id: id, privacyClass: .clinical)
        _ = try await store.updateTitleOverride(id: id, titleOverride: "My notes")
        let done = await pipeline.process(id: id)
        XCTAssertEqual(done?.privacyClass, .clinical)
        XCTAssertEqual(done?.displayTitle, "My notes")
        XCTAssertEqual(done?.documentFormat, .docx)
    }

    func testFailureIsReadableAndRetryExtractsAgain() async throws {
        let extractor = FakeExtractor(.fail(.passwordProtected))
        let pipeline = makePipeline(extractor)
        let id = try await pipeline.importItem(from: try makeFile("locked.pdf"))
        let failed = await pipeline.process(id: id)
        XCTAssertEqual(failed?.status, .failed)
        XCTAssertEqual(failed?.errorMessage, DocumentExtractionError.passwordProtected.errorDescription)

        extractor.setBehavior(.succeed(Self.extracted))
        let retried = await pipeline.retry(id: id)
        XCTAssertEqual(retried?.status, .completed)
        XCTAssertNil(retried?.errorMessage)
        let again = await pipeline.retry(id: id)
        XCTAssertNil(again, "a completed row is not retried")
    }

    func testCancelEndsCancelled() async throws {
        let extractor = FakeExtractor(.waitForCancel)
        let pipeline = makePipeline(extractor)
        let id = try await pipeline.importItem(from: try makeFile("big.pdf"))
        let task = Task { await pipeline.process(id: id) }
        await extractor.started.wait()
        task.cancel()
        let ended = await task.value
        XCTAssertEqual(ended?.status, .cancelled)
    }

    func testUnsupportedFileLeavesNothingBehind() async throws {
        let pipeline = makePipeline(FakeExtractor(.succeed(Self.extracted)))
        do {
            _ = try await pipeline.importItem(from: try makeFile("slides.key"))
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? DocumentExtractionError, .unsupportedFormat("key"))
        }
        let media = paths.root.appendingPathComponent("media")
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: media.path)) ?? [], [])
        let rows = try await store.fetchAll()
        XCTAssertTrue(rows.isEmpty)
        XCTAssertTrue(DocumentImportPipeline.canImport(URL(fileURLWithPath: "/a/b.md")))
        XCTAssertFalse(DocumentImportPipeline.canImport(URL(fileURLWithPath: "/a/b.m4a")))
    }

    func testDeletedDuringExtractionIsNotRecreated() async throws {
        let extractor = FakeExtractor(.waitForCancel)
        let pipeline = makePipeline(extractor)
        let id = try await pipeline.importItem(from: try makeFile("handout.txt"))
        try await store.delete(id: id)
        extractor.setBehavior(.succeed(Self.extracted))
        let result = await pipeline.process(id: id)
        XCTAssertNil(result)
    }

    @MainActor
    func testJobCenterRunsDocumentsAndSettlesEachIncomingFile() async throws {
        let pipeline = makePipeline(FakeExtractor(.succeed(Self.extracted)))
        let center = TranscriptionJobCenter()
        var settled: [String] = []
        center.onImportSettled = { settled.append($0.lastPathComponent) }
        let good = try makeFile("notes.md")
        let bad = try makeFile("archive.zip")
        center.start(filesAt: [good, bad], importer: pipeline)
        await center.waitUntilIdle()
        XCTAssertEqual(Set(settled), ["notes.md", "archive.zip"])
        XCTAssertNotNil(center.lastImportError, "the unsupported file is reported")
        let rows = try await store.fetchAll()
        XCTAssertEqual(rows.map(\.status), [.completed])
        XCTAssertEqual(rows.first?.documentFormat, .markdown)
    }
}
