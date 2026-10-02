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
