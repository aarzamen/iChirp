import ChirpCore
import ChirpIngest
import Foundation
import Synchronization
import XCTest

@testable import ChirpFeatures

/// Answers per URL: `refused` URLs fail with HTTP 403 (an expired signed link), everything else downloads. Records
/// every URL it was asked for.
final class URLScriptedDownloader: MediaDownloading {
    private let refused: Set<String>
    private let calls = Mutex<[URL]>([])

    init(refusing refused: Set<String>) {
        self.refused = refused
    }

    var urls: [URL] { calls.withLock { $0 } }

    func download(
        from url: URL, into directory: URL, fileStem: String,
        progress: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws -> DownloadedFile {
        calls.withLock { $0.append(url) }
        if refused.contains(url.absoluteString) { throw IngestNetworkError.httpStatus(403) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("\(fileStem).mp3")
        try Data([1, 2, 3]).write(to: file)
        return DownloadedFile(fileURL: file, mimeType: "audio/mpeg", byteCount: 3, resumed: false)
    }
}

/// A web link that redirects to a signed, expiring address: `example.com` → 302 → `signed.example.com/…?sig=…`,
/// which serves video. No real network.
///
/// `@unchecked Sendable`: URLProtocol subclasses are created and driven by the URL loading system; this one keeps no
/// mutable state.
final class SignedRedirectStubProtocol: URLProtocol, @unchecked Sendable {
    static let signed = URL(string: "https://signed.example.com/file.mp4?sig=abc&expires=1")!

    static func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SignedRedirectStubProtocol.self]
        return configuration
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        if url.host() == "example.com" {
            let redirect = HTTPURLResponse(
                url: url, statusCode: 302, httpVersion: "HTTP/1.1",
                headerFields: ["Location": Self.signed.absoluteString])!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: Self.signed), redirectResponse: redirect)
            return
        }
        let answer = HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "video/mp4"])!
        client?.urlProtocol(self, didReceive: answer, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Review R2-12: a web link downloads (and resumes) from the link itself, so an expired signed redirect is followed
/// afresh; a Retry whose recorded download address is refused (401/403) resolves the link again once.
final class LinkIngestRetryTests: XCTestCase {
    private var root: URL!
    private var paths: AppPaths!
    private let store = FakeStore()
    private let episodeLink = URL(string: "https://podcasts.apple.com/us/podcast/ep-5/id1000000001?i=1000000000002")!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LinkIngestRetryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        paths = AppPaths(root: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeService(
        downloader: any MediaDownloading, podcasts: FakePodcasts = FakePodcasts(),
        http: IngestHTTPClient = IngestHTTPClient(configuration: .ephemeral)
    ) -> LinkIngestService {
        LinkIngestService(
            paths: paths, store: store, http: http, downloader: downloader, podcasts: podcasts,
            captions: FakeCaptions(result: .success(FakeCaptions.sample)), preferredLanguages: { ["en"] },
            onProgress: { _, _ in })
    }

    func testAWebLinkDownloadsFromTheLinkItselfNotItsSignedRedirect() async throws {
        let service = makeService(
            downloader: URLScriptedDownloader(refusing: []),
            http: IngestHTTPClient(configuration: SignedRedirectStubProtocol.configuration()))
        let link = URL(string: "https://example.com/download?id=7")!
        guard case .media(let source) = try await service.resolve(.webLink(link)) else {
            return XCTFail("expected media")
        }
        XCTAssertEqual(source.downloadURL, link, "the signed address expires; the link does not")
        XCTAssertEqual(source.link, link)
        XCTAssertEqual(source.sourceType, .url)
    }

    func testRetryResolvesTheLinkAgainWhenTheRecordedAddressIsRefused() async throws {
        let expired = "https://cdn.example.com/signed/ep5.mp3?expires=1"
        let downloader = URLScriptedDownloader(refusing: [expired])
        var podcasts = FakePodcasts()
        podcasts.episode = ResolvedPodcastEpisode(
            audioURL: "https://cdn.example.com/fresh/ep5.mp3", episodeTitle: "Ep. 5: A Synthetic Episode")
        let service = makeService(downloader: downloader, podcasts: podcasts)
        let id = try await service.createRow(
            for: try LinkIngestService.source(for: podcasts.episode, link: episodeLink))

        // The first download stopped partway on a signed address (recorded in download.part.json), then failed.
        let folder = paths.mediaDirectory(for: id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(repeating: 9, count: 100).write(to: folder.appendingPathComponent(MediaDownloader.partialFileName))
        try JSONSerialization.data(withJSONObject: ["url": expired])
            .write(to: folder.appendingPathComponent(MediaDownloader.partialInfoFileName))
        guard case .ended(let failed) = await service.download(id: id, from: URL(string: expired)!) else {
            return XCTFail("expected the download to end")
        }
        XCTAssertEqual(failed?.status, .failed)

        let retried = await service.retryDownload(id: id)
        XCTAssertEqual(retried, .ready, "Retry resolved the episode again instead of failing on the expired address")
        XCTAssertEqual(
            downloader.urls.map(\.absoluteString), [expired, expired, "https://cdn.example.com/fresh/ep5.mp3"])
        let stored = await store.row(id)
        XCTAssertEqual(stored?.mediaRelativePath, "media/\(id.uuidString)/source.mp3")
    }

    /// A refusal for a freshly resolved address is final: no second lookup.
    func testARefusedFreshAddressFailsWithoutAnotherLookup() async throws {
        let link = URL(string: "https://cdn.example.com/private/a.mp3")!
        let downloader = URLScriptedDownloader(refusing: [link.absoluteString])
        let service = makeService(downloader: downloader)
        let id = try await service.createRow(for: LinkMediaSource(downloadURL: link, link: link, sourceType: .url))
        _ = await service.download(id: id, from: link)
        guard case .ended(let row) = await service.retryDownload(id: id) else { return XCTFail("expected an end") }
        XCTAssertEqual(row?.status, .failed)
        XCTAssertEqual(row?.errorMessage, IngestNetworkError.httpStatus(403).errorDescription)
        XCTAssertEqual(downloader.urls, [link, link])
    }
}
