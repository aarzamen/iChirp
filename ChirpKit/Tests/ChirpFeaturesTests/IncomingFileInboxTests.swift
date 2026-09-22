import ChirpCore
import Foundation
import XCTest

@testable import ChirpFeatures

/// M1.5 Step 1: a file another app hands to Parakeet arrives as iOS's copy in `Documents/Inbox/`; it is imported like
/// a picked file and that temporary copy is deleted once the import settles. Nothing outside the inbox is deleted.
@MainActor
final class IncomingFileInboxTests: XCTestCase {
    nonisolated(unsafe) private var base: URL!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("IncomingFileInboxTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
    }

    private func makeFile(_ relativePath: String) throws -> URL {
        let url = base.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 3, count: 256).write(to: url)
        return url
    }

    func testContainsOnlyFilesStrictlyInsideTheInbox() throws {
        let inbox = IncomingFileInbox(directory: base.appendingPathComponent("Inbox", isDirectory: true))
        XCTAssertTrue(inbox.contains(try makeFile("Inbox/memo.m4a")))
        XCTAssertTrue(inbox.contains(try makeFile("Inbox/nested/memo.m4a")))
        XCTAssertFalse(inbox.contains(try makeFile("Picked/memo.m4a")), "a picked file is the user's own")
        XCTAssertFalse(inbox.contains(try makeFile("InboxNot/memo.m4a")), "a sibling with the same prefix")
        XCTAssertFalse(inbox.contains(inbox.directory), "the inbox folder itself")
        XCTAssertFalse(inbox.contains(try XCTUnwrap(URL(string: "https://example.com/memo.m4a"))))
    }

    func testRemoveIfInsideDeletesOnlyInboxFiles() throws {
        let inbox = IncomingFileInbox(directory: base.appendingPathComponent("Inbox", isDirectory: true))
        let shared = try makeFile("Inbox/memo.m4a")
        let picked = try makeFile("Picked/memo.m4a")

        XCTAssertTrue(inbox.removeIfInside(shared))
        XCTAssertFalse(inbox.removeIfInside(picked))

        XCTAssertFalse(fileExists(shared))
        XCTAssertTrue(fileExists(picked), "never delete a file outside the inbox")
        XCTAssertFalse(inbox.removeIfInside(shared), "already gone is harmless")
    }

    func testAppDefaultIsDocumentsInbox() throws {
        let inbox = try XCTUnwrap(IncomingFileInbox.appDefault())
        XCTAssertEqual(inbox.directory.lastPathComponent, "Inbox")
        XCTAssertEqual(inbox.directory.deletingLastPathComponent().lastPathComponent, "Documents")
    }

    /// The import-from-URL path end to end: the shared file becomes a completed row with its own copy in
    /// `media/<id>/`, and iOS's Inbox copy is gone once the import settled.
    func testSharedFileIsImportedTranscribedAndItsInboxCopyRemoved() async throws {
        let center = TranscriptionJobCenter()
        let h = try PipelineHarness(testCase: self, onProgress: center.progressHandler)
        let inbox = IncomingFileInbox(directory: h.inbox)
        var settled: [URL] = []
        center.onImportSettled = { url in
            settled.append(url)
            inbox.removeIfInside(url)
        }
        let shared = try h.makeSourceFile(named: "Voice Memo.m4a")

        center.start(filesAt: [shared], pipeline: h.pipeline)
        await center.waitUntilIdle()

        let rows = try await h.store.fetchAll()
        XCTAssertEqual(rows.map(\.status), [.completed])
        XCTAssertEqual(rows.first?.fileName, "Voice Memo.m4a")
        let id = try XCTUnwrap(rows.first?.id)
        XCTAssertTrue(fileExists(h.sourceURL(for: id)), "the imported copy in media/<id>/ is the user's data")
        XCTAssertEqual(settled, [shared])
        XCTAssertFalse(fileExists(shared), "iOS's temporary Inbox copy is deleted after the import")
    }

    func testFailedImportStillSettlesAndLeavesNoRow() async throws {
        let center = TranscriptionJobCenter()
        let h = try PipelineHarness(testCase: self, onProgress: center.progressHandler)
        var settled: [URL] = []
        center.onImportSettled = { settled.append($0) }
        let missing = h.inbox.appendingPathComponent("gone.m4a")

        center.start(filesAt: [missing], pipeline: h.pipeline)
        await center.waitUntilIdle()

        XCTAssertEqual(settled, [missing])
        XCTAssertNotNil(center.lastImportError)
        let rows = try await h.store.fetchAll()
        XCTAssertTrue(rows.isEmpty)
    }

    func testRetryNeverSettlesAnIncomingFile() async throws {
        let center = TranscriptionJobCenter()
        let h = try PipelineHarness(testCase: self, onProgress: center.progressHandler)
        await h.speech.failTranscription(with: FakeError(message: "engine hiccup"))
        var settled: [URL] = []
        center.onImportSettled = { settled.append($0) }
        center.start(filesAt: [try h.makeSourceFile()], pipeline: h.pipeline)
        await center.waitUntilIdle()
        let fetchedId = try await h.store.fetchAll().first?.id
        let id = try XCTUnwrap(fetchedId)
        settled = []

        await h.speech.failTranscription(with: nil)
        center.retry(id, pipeline: h.pipeline)
        await center.waitUntilIdle()

        XCTAssertTrue(settled.isEmpty)
    }
}

/// M5: shared documents go to the document path; audio and video stay on the file pipeline.
final class IncomingFileKindTests: XCTestCase {
    func testDocumentsAndOtherTextAreDocumentsEverythingElseIsMedia() {
        for name in ["a.pdf", "b.DOCX", "c.md", "d.rtf", "e.html", "f.txt", "g.csv", "h.log"] {
            XCTAssertEqual(IncomingFileInbox.kind(of: URL(fileURLWithPath: "/tmp/\(name)")), .document, name)
        }
        for name in ["a.m4a", "b.mov", "c.mp3", "d.wav", "e", "f.zip"] {
            XCTAssertEqual(IncomingFileInbox.kind(of: URL(fileURLWithPath: "/tmp/\(name)")), .media, name)
        }
        XCTAssertEqual(DocumentImportPipeline.format(of: URL(fileURLWithPath: "/tmp/notes.log")), .plainText)
    }
}
