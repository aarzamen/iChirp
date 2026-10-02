import XCTest

@testable import ChirpIngest

final class IngestHTTPClientTests: XCTestCase {
    private let client = IngestHTTPClient(configuration: IngestStubURLProtocol.configuration())

    func testProbeUsesHeadAndReadsTheContentType() async throws {
        IngestStubURLProtocol.reset { _ in
            IngestStubResponse(status: 200, headers: ["Content-Type": "audio/mpeg; charset=binary"], chunks: [])
        }
        let result = try await client.probe(URL(string: "https://example.com/get?id=1")!)
        XCTAssertEqual(result.kind, .media)
        XCTAssertEqual(result.mimeType, "audio/mpeg")
        XCTAssertEqual(IngestStubURLProtocol.requests.map(\.method), ["HEAD"])
    }

    func testProbeFallsBackToAOneByteGetWhenHeadIsRefused() async throws {
        IngestStubURLProtocol.reset { request in
            if request.method == "HEAD" { return .text("", status: 405) }
            return IngestStubResponse(status: 206, headers: ["Content-Type": "text/html"], chunks: [Data("<".utf8)])
        }
        let result = try await client.probe(URL(string: "https://example.com/page")!)
        XCTAssertEqual(result.kind, .webPage)
        XCTAssertEqual(IngestStubURLProtocol.requests.map(\.method), ["HEAD", "GET"])
        XCTAssertEqual(IngestStubURLProtocol.requests.last?.header("Range"), "bytes=0-0")
    }

    /// Review R2-4: a body bigger than the limit is refused while it streams, not after all of it is in memory.
    func testABodyOverTheLimitStopsWhileStreaming() async {
        IngestStubURLProtocol.reset { _ in
            IngestStubResponse(
                status: 200, headers: ["Content-Type": "application/rss+xml"],
                streamed: (Data(repeating: 0x20, count: 256 * 1_024), 40))
        }
        do {
            _ = try await client.get(URL(string: "https://example.com/feed")!, maximumBytes: 64 * 1_024)
            XCTFail("expected tooLarge")
        } catch {
            XCTAssertEqual(error as? IngestNetworkError, .tooLarge)
        }
        XCTAssertLessThan(IngestStubURLProtocol.deliveredBytes, 2 * 1_024 * 1_024, "10 MB were offered")
    }

    /// A declared length over the limit is refused at the headers.
    func testADeclaredLengthOverTheLimitIsRefusedAtTheHeaders() async {
        IngestStubURLProtocol.reset { _ in
            IngestStubResponse(
                status: 200, headers: ["Content-Type": "text/xml", "Content-Length": "\(10 * 1_024 * 1_024)"],
                streamed: (Data(repeating: 0x20, count: 256 * 1_024), 40))
        }
        do {
            _ = try await client.get(URL(string: "https://example.com/feed")!, maximumBytes: 64 * 1_024)
            XCTFail("expected tooLarge")
        } catch {
            XCTAssertEqual(error as? IngestNetworkError, .tooLarge)
        }
        XCTAssertLessThan(IngestStubURLProtocol.deliveredBytes, 2 * 1_024 * 1_024)
    }

    /// The probe's fallback GET reads only the headers, even from a server that ignores `Range` and sends a whole
    /// video.
    func testProbeFallbackReadsOnlyTheHeadersWhenRangeIsIgnored() async throws {
        IngestStubURLProtocol.reset { request in
            if request.method == "HEAD" { return .text("", status: 405) }
            return IngestStubResponse(
                status: 200, headers: ["Content-Type": "video/mp4"],
                streamed: (Data(repeating: 0, count: 256 * 1_024), 40))
        }
        let result = try await client.probe(URL(string: "https://example.com/download?id=7")!)
        XCTAssertEqual(result.kind, .media)
        XCTAssertEqual(result.mimeType, "video/mp4")
        XCTAssertLessThan(IngestStubURLProtocol.deliveredBytes, 2 * 1_024 * 1_024)
    }

    func testABodyWithinTheLimitIsReturnedWhole() async throws {
        IngestStubURLProtocol.reset { _ in
            IngestStubResponse(
                status: 200, headers: ["Content-Type": "application/json"],
                streamed: (Data(repeating: 0x31, count: 10_000), 5))
        }
        let (data, response) = try await client.get(URL(string: "https://example.com/a")!, maximumBytes: 50_000)
        XCTAssertEqual(data, Data(repeating: 0x31, count: 50_000))
        XCTAssertEqual(response.statusCode, 200)
    }

    // MARK: - Plain http (review R2-2)

    /// iOS blocks plain http to internet hosts, so the request goes out over https.
    func testPlainHTTPToAnInternetHostIsRequestedOverHTTPS() async throws {
        IngestStubURLProtocol.reset { _ in .text("<rss/>", contentType: "application/rss+xml") }
        _ = try await client.get(URL(string: "http://feeds.example.com/show.rss?x=1")!)
        XCTAssertEqual(
            IngestStubURLProtocol.requests.map(\.url.absoluteString), ["https://feeds.example.com/show.rss?x=1"])

        IngestStubURLProtocol.reset { _ in IngestStubResponse(status: 200, headers: ["Content-Type": "audio/mpeg"]) }
        let probed = try await client.probe(URL(string: "http://cdn.example.com:80/get?id=1")!)
        XCTAssertEqual(IngestStubURLProtocol.requests.first?.url.absoluteString, "https://cdn.example.com/get?id=1")
        XCTAssertEqual(probed.kind, .media)
    }

    /// The home network may use plain http (iOS allows it there), so those links are left alone.
    func testPlainHTTPOnTheHomeNetworkStaysHTTP() async throws {
        IngestStubURLProtocol.reset { _ in .text("<rss/>", contentType: "application/rss+xml") }
        for link in ["http://192.168.1.20/feed.rss", "http://nas.local/feed.rss", "http://nas/feed.rss"] {
            _ = try await client.get(URL(string: link)!)
        }
        XCTAssertEqual(
            IngestStubURLProtocol.requests.map(\.url.absoluteString),
            ["http://192.168.1.20/feed.rss", "http://nas.local/feed.rss", "http://nas/feed.rss"])
    }

    /// A redirect to plain http is followed over https.
    func testARedirectToPlainHTTPIsFollowedOverHTTPS() async throws {
        IngestStubURLProtocol.reset { request in
            request.url.path() == "/start"
                ? .redirect(to: URL(string: "http://cdn.example.com/feed.rss")!)
                : .text("<rss/>", contentType: "application/rss+xml")
        }
        _ = try await client.get(URL(string: "https://example.com/start")!)
        XCTAssertEqual(
            IngestStubURLProtocol.requests.map(\.url.absoluteString),
            ["https://example.com/start", "https://cdn.example.com/feed.rss"])
    }

    /// When the upgraded link fails over https, the error says why in plain words.
    func testAnUpgradedLinkThatFailsOverHTTPSSaysWhy() async {
        IngestStubURLProtocol.reset { _ in .fail(.secureConnectionFailed) }
        do {
            _ = try await client.get(URL(string: "http://old.example.com/feed.rss")!)
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? IngestNetworkError, .httpsUnavailable)
            let message = (error as? IngestNetworkError)?.errorDescription ?? ""
            XCTAssertTrue(message.contains("https"), message)
            XCTAssertFalse(message.contains("App Transport Security"), message)
        }
        // The same failure on a link that was https all along keeps the general message.
        IngestStubURLProtocol.reset { _ in .fail(.secureConnectionFailed) }
        do {
            _ = try await client.get(URL(string: "https://old.example.com/feed.rss")!)
            XCTFail("expected an error")
        } catch {
            XCTAssertNotEqual(error as? IngestNetworkError, .httpsUnavailable)
        }
    }

    func testAppTransportSecurityRefusalReadsAsAPlainSentence() {
        let mapped = IngestNetworkError.map(URLError(.appTransportSecurityRequiresSecureConnection))
        XCTAssertEqual(mapped as? IngestNetworkError, .insecureLink)
        let message = (mapped as? IngestNetworkError)?.errorDescription ?? ""
        XCTAssertFalse(message.contains("App Transport Security"), message)
        XCTAssertTrue(message.contains("https"), message)
    }

    /// Review R2-9: a web link that serves Ogg, Opus or WebM is refused at the probe, before any row exists.
    func testProbeRefusesMediaIOSCannotDecode() async {
        IngestStubURLProtocol.reset { _ in
            IngestStubResponse(status: 200, headers: ["Content-Type": "audio/ogg; codecs=opus"])
        }
        do {
            _ = try await client.probe(URL(string: "https://example.com/get?id=1")!)
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual(error as? MediaDownloadError, .unsupportedFormat("Ogg"))
        }
    }

    func testNon2xxIsAReadableError() async {
        IngestStubURLProtocol.reset { _ in .text("slow down", status: 429) }
        do {
            _ = try await client.get(URL(string: "https://example.com/a")!)
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? IngestNetworkError, .httpStatus(429))
            XCTAssertTrue((error as? IngestNetworkError)?.errorDescription?.contains("Wait a minute") == true)
        }
    }

    func testURLErrorsMapToPlainMessages() {
        XCTAssertEqual(
            IngestNetworkError.map(URLError(.notConnectedToInternet)) as? IngestNetworkError, .offline)
        XCTAssertEqual(IngestNetworkError.map(URLError(.timedOut)) as? IngestNetworkError, .timedOut)
        XCTAssertTrue(IngestNetworkError.map(URLError(.cancelled)) is CancellationError)
    }
}
