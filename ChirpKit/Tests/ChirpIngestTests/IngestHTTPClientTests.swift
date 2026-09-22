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
