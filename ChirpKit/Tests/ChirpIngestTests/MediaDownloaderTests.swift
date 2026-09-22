import Synchronization
import XCTest

@testable import ChirpIngest

/// `MediaDownloader` against `IngestStubURLProtocol`: no real network.
final class MediaDownloaderTests: XCTestCase {
    private var directory: URL!
    private let downloader = MediaDownloader(configuration: { IngestStubURLProtocol.configuration() })
    private static let payload = Data((0..<200_000).map { UInt8($0 % 251) })

    override func setUpWithError() throws {
        directory = try makeTemporaryDirectory()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testDownloadsIntoTheFolderWithRealProgress() async throws {
        let chunks = stride(from: 0, to: Self.payload.count, by: 50_000).map {
            Self.payload[$0..<min($0 + 50_000, Self.payload.count)]
        }
        IngestStubURLProtocol.reset { _ in
            IngestStubResponse(
                status: 200,
                headers: ["Content-Type": "audio/mpeg", "Content-Length": "\(Self.payload.count)", "ETag": "\"v1\""],
                chunks: chunks.map { Data($0) })
        }
        let recorder = ProgressRecorder()
        let file = try await downloader.download(
            from: URL(string: "https://cdn.example.com/audio/episode.mp3")!, into: directory, fileStem: "source",
            progress: recorder.record)

        XCTAssertEqual(file.fileURL.lastPathComponent, "source.mp3")
        XCTAssertEqual(try Data(contentsOf: file.fileURL), Self.payload)
        XCTAssertEqual(file.byteCount, Int64(Self.payload.count))
        XCTAssertFalse(file.resumed)
        let fractions = recorder.values.compactMap(\.fraction)
        XCTAssertEqual(fractions.first, 0)
        XCTAssertEqual(fractions.last, 1)
        XCTAssertEqual(fractions, fractions.sorted(), "progress never goes backwards")
        // URLSession may coalesce the stub's chunks, so only the start and the end are guaranteed here.
        XCTAssertGreaterThanOrEqual(Set(fractions).count, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: partURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: infoURL.path))
        let request = try XCTUnwrap(IngestStubURLProtocol.requests.first)
        XCTAssertNil(request.header("Range"))
        XCTAssertEqual(request.header("User-Agent"), IngestHTTPClient.userAgent)
    }

    func testExtensionComesFromTheContentTypeWhenTheLinkHasNone() async throws {
        IngestStubURLProtocol.reset { _ in .body(Self.payload, contentType: "audio/mp4") }
        let file = try await downloader.download(
            from: URL(string: "https://cdn.example.com/get?id=7")!, into: directory, fileStem: "source",
            progress: { _ in })
        XCTAssertEqual(file.fileURL.lastPathComponent, "source.m4a")
    }

    func testHTTPErrorLeavesNoFile() async throws {
        IngestStubURLProtocol.reset { _ in .text("gone", status: 404) }
        do {
            _ = try await downloader.download(
                from: URL(string: "https://cdn.example.com/a.mp3")!, into: directory, fileStem: "source",
                progress: { _ in })
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? IngestNetworkError, .httpStatus(404))
            XCTAssertTrue(Formatting.readable(error).contains("404"))
        }
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(leftovers.filter { $0.hasPrefix("source") }, [])
    }

    func testWebPageIsRefusedAsNotMedia() async throws {
        IngestStubURLProtocol.reset { _ in .text("<html></html>", contentType: "text/html") }
        do {
            _ = try await downloader.download(
                from: URL(string: "https://example.com/a.mp3")!, into: directory, fileStem: "source",
                progress: { _ in })
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? MediaDownloadError, .notMedia(contentType: "text/html"))
        }
    }

    func testRetryResumesFromThePartialFileWithRangeAndIfRange() async throws {
        let half = 80_000
        try Self.payload.prefix(half).write(to: partURL)
        let info = MediaDownloader.PartialInfo(
            url: "https://cdn.example.com/a.mp3", etag: "\"v1\"", lastModified: nil,
            totalBytes: Int64(Self.payload.count))
        try JSONEncoder().encode(info).write(to: infoURL)
        IngestStubURLProtocol.reset { request in
            guard request.header("Range") == "bytes=\(half)-", request.header("If-Range") == "\"v1\"" else {
                return .body(Self.payload, contentType: "audio/mpeg")
            }
            let rest = Self.payload.suffix(from: half)
            return IngestStubResponse(
                status: 206,
                headers: [
                    "Content-Type": "audio/mpeg", "Content-Length": "\(rest.count)",
                    "Content-Range": "bytes \(half)-\(Self.payload.count - 1)/\(Self.payload.count)",
                ],
                chunks: [Data(rest)])
        }
        let recorder = ProgressRecorder()
        let file = try await downloader.download(
            from: URL(string: "https://cdn.example.com/a.mp3")!, into: directory, fileStem: "source",
            progress: recorder.record)

        XCTAssertTrue(file.resumed)
        XCTAssertEqual(try Data(contentsOf: file.fileURL), Self.payload)
        XCTAssertEqual(recorder.values.first?.bytesReceived, Int64(half), "progress starts at the resumed offset")
        XCTAssertEqual(IngestStubURLProtocol.requests.count, 1)
    }

    func testServerThatIgnoresRangeRestartsFromZero() async throws {
        try Data(repeating: 9, count: 1_000).write(to: partURL)
        try JSONEncoder().encode(
            MediaDownloader.PartialInfo(
                url: "https://cdn.example.com/a.mp3", etag: nil, lastModified: "Mon, 01 Jan 2024 00:00:00 GMT",
                totalBytes: nil)
        ).write(to: infoURL)
        IngestStubURLProtocol.reset { _ in .body(Self.payload, contentType: "audio/mpeg") }
        let file = try await downloader.download(
            from: URL(string: "https://cdn.example.com/a.mp3")!, into: directory, fileStem: "source",
            progress: { _ in })
        XCTAssertFalse(file.resumed)
        XCTAssertEqual(try Data(contentsOf: file.fileURL), Self.payload, "the stale partial bytes are gone")
        XCTAssertEqual(IngestStubURLProtocol.requests.first?.header("Range"), "bytes=1000-")
    }

    func testMismatchedContentRangeStartsOverOnce() async throws {
        try Data(repeating: 9, count: 1_000).write(to: partURL)
        try JSONEncoder().encode(
            MediaDownloader.PartialInfo(url: "https://cdn.example.com/a.mp3", etag: "\"v1\"", lastModified: nil)
        ).write(to: infoURL)
        IngestStubURLProtocol.reset { request in
            if request.header("Range") != nil {
                return IngestStubResponse(
                    status: 206, headers: ["Content-Type": "audio/mpeg", "Content-Range": "bytes 0-9/200000"],
                    chunks: [Data(repeating: 1, count: 10)])
            }
            return .body(Self.payload, contentType: "audio/mpeg")
        }
        let file = try await downloader.download(
            from: URL(string: "https://cdn.example.com/a.mp3")!, into: directory, fileStem: "source",
            progress: { _ in })
        XCTAssertEqual(try Data(contentsOf: file.fileURL), Self.payload)
        XCTAssertEqual(IngestStubURLProtocol.requests.count, 2)
        XCTAssertNil(IngestStubURLProtocol.requests.last?.header("Range"))
    }

    func testCancellingKeepsThePartialFileForResume() async throws {
        IngestStubURLProtocol.reset { _ in
            IngestStubResponse(
                status: 200,
                headers: ["Content-Type": "audio/mpeg", "Content-Length": "\(Self.payload.count)", "ETag": "\"v2\""],
                chunks: [Data(Self.payload.prefix(40_000))], hangsAfterFirstChunk: true)
        }
        let started = expectation(description: "first bytes written")
        let fired = Mutex(false)
        let task = Task { [downloader, directory] in
            try await downloader.download(
                from: URL(string: "https://cdn.example.com/a.mp3")!, into: directory!, fileStem: "source",
                progress: { progress in
                    if progress.bytesReceived >= 40_000,
                        fired.withLock({
                            let was = $0; $0 = true; return !was
                        })
                    {
                        started.fulfill()
                    }
                })
        }
        await fulfillment(of: [started], timeout: 5)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError, "got \(error)")
        }
        let partSize = try FileManager.default.attributesOfItem(atPath: partURL.path)[.size] as? NSNumber
        XCTAssertEqual(partSize?.intValue, 40_000)
        let resume = MediaDownloader.resumePoint(
            partURL: partURL, infoURL: infoURL, for: URL(string: "https://cdn.example.com/a.mp3")!)
        XCTAssertEqual(resume, MediaDownloader.ResumePoint(offset: 40_000, validator: "\"v2\""))
    }

    func testNonHTTPLinksAreRefused() async {
        do {
            _ = try await downloader.download(
                from: URL(string: "file:///tmp/a.mp3")!, into: directory, fileStem: "source", progress: { _ in })
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? MediaDownloadError, .invalidURL)
        }
    }

    func testContentRangeParsing() {
        XCTAssertEqual(MediaDownloader.contentRange("bytes 100-199/1000")?.start, 100)
        XCTAssertEqual(MediaDownloader.contentRange("bytes 100-199/1000")?.total, 1000)
        XCTAssertNil(MediaDownloader.contentRange("bytes 100-199/*")?.total)
        XCTAssertNil(MediaDownloader.contentRange("items 1-2/3"))
    }

    // MARK: - Helpers

    private var partURL: URL { directory.appendingPathComponent(MediaDownloader.partialFileName) }
    private var infoURL: URL { directory.appendingPathComponent(MediaDownloader.partialInfoFileName) }
}

/// Collects progress reports from any thread.
final class ProgressRecorder: Sendable {
    private let storage = Mutex<[DownloadProgress]>([])

    var values: [DownloadProgress] { storage.withLock { $0 } }

    var record: @Sendable (DownloadProgress) -> Void {
        { [self] progress in storage.withLock { $0.append(progress) } }
    }
}

enum Formatting {
    static func readable(_ error: any Error) -> String {
        (error as? any LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
