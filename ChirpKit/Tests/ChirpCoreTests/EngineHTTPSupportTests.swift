import Foundation
import Synchronization
import XCTest

@testable import ChirpCore

/// Review R3-4: the key scrubber and the response-size cap every HTTP engine (language models, Jev, voices) shares,
/// instead of three copies that had drifted. Every key below is synthetic.
final class EngineHTTPSupportTests: XCTestCase {
    // MARK: - Scrubber

    func testEveryKeyShapeTheEnginesMeetIsScrubbed() {
        let echoes = [
            "sk-proj-ABCDEFGH12345",  // OpenAI
            "sk-ant-api03-ABCDEFGH12345",  // Anthropic
            "sk-or-v1-ABCDEFGH12345",  // OpenRouter
            "xai-ABCDEFGH12345678",  // xAI
            "gsk_ABCDEFGH12345678",  // Groq
            "AIzaSyABCDEFGHIJKLMNOPQRSTUVWX",  // Google (Gemini)
        ]
        for echo in echoes {
            let scrubbed = ProviderMessageScrubber.scrubbed("invalid key \(echo) for this model")
            XCTAssertFalse(scrubbed.contains(echo), scrubbed)
            XCTAssertTrue(scrubbed.contains("<api-key>"), scrubbed)
        }
        let headers = ProviderMessageScrubber.scrubbed(
            "sent Bearer abcdefgh12345678, x-api-key: abcdefgh12345678, api_key=abcdefgh12345678 and "
                + "key=AAAAAAAAAAAAAAAAAAAA")
        XCTAssertFalse(headers.contains("abcdefgh12345678"), headers)
        XCTAssertFalse(headers.contains("AAAAAAAAAAAAAAAAAAAA"), headers)
    }

    func testTheLiteralKeyIsScrubbedWhateverItsShape() {
        let key = SecretValue("ts-TESTKEY-0123456789abcdefghij")
        let scrubbed = ProviderMessageScrubber.scrubbed("rejected ts-TESTKEY-0123456789abcdefghij today", secret: key)
        XCTAssertEqual(scrubbed, "rejected <api-key> today")
        XCTAssertEqual(
            ProviderMessageScrubber.scrubbed("abc stays", secret: SecretValue("abc")), "abc stays",
            "a 1–3 character secret would mask ordinary words")
    }

    func testScrubbingIsIdempotentAndLeavesOrdinaryErrorsAlone() {
        let plain = "The model llama3.1:8b was not found. Context length 8192 exceeded by 12 tokens."
        XCTAssertEqual(ProviderMessageScrubber.scrubbed(plain), plain)
        let once = ProviderMessageScrubber.scrubbed("bad sk-proj-ABCDEFGH12345 and Bearer abcdefgh12345678")
        XCTAssertEqual(ProviderMessageScrubber.scrubbed(once), once)
    }

    func testDisplayableMessagesAreScrubbedThenShortened() {
        let long = "sk-proj-ABCDEFGH12345 " + String(repeating: "x", count: 1_000)
        let shown = ProviderMessageScrubber.displayable(long)
        XCTAssertTrue(shown.hasPrefix("<api-key> "), shown)
        XCTAssertEqual(shown.count, ProviderMessageScrubber.maxMessageCharacters + 1, "300 characters and an ellipsis")
        XCTAssertTrue(shown.hasSuffix("…"))
        XCTAssertEqual(ProviderMessageScrubber.displayable("  short  \n"), "short")
    }

    // MARK: - Response-size cap

    func testABodyUnderTheLimitIsReadWhole() async throws {
        let body = Data(repeating: 7, count: 4_096)
        let data = try await collect(body, chunks: 4, limit: 4_096)
        XCTAssertEqual(data, body)
    }

    func testABodyPastTheLimitIsRefusedAsItArrives() async {
        do {
            _ = try await collect(Data(repeating: 7, count: 10_000), chunks: 10, limit: 4_096, declaresLength: false)
            XCTFail("a body past the limit must be refused")
        } catch {
            XCTAssertEqual(error as? BoundedResponseBody.TooLarge, BoundedResponseBody.TooLarge(limit: 4_096))
        }
    }

    func testADeclaredLengthPastTheLimitIsRefusedBeforeReading() async {
        do {
            _ = try await collect(Data(repeating: 7, count: 10_000), chunks: 1, limit: 4_096, declaresLength: true)
            XCTFail("a declared length past the limit must be refused")
        } catch {
            XCTAssertEqual(error as? BoundedResponseBody.TooLarge, BoundedResponseBody.TooLarge(limit: 4_096))
        }
    }

    private func collect(_ body: Data, chunks: Int, limit: Int, declaresLength: Bool = true) async throws -> Data {
        BoundedBodyStub.set(body: body, chunks: chunks, declaresLength: declaresLength)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BoundedBodyStub.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(from: URL(string: "https://example.invalid/body")!)
        return try await BoundedResponseBody.collect(bytes, expectedLength: response.expectedContentLength, limit: limit)
    }
}

/// Serves one canned body in chunks, with or without a `Content-Length`.
private final class BoundedBodyStub: URLProtocol, @unchecked Sendable {
    // @unchecked Sendable: URLProtocol is not Sendable; the stub's own state is behind `state`.
    private struct Canned {
        var body = Data()
        var chunks = 1
        var declaresLength = true
    }

    private static let state = Mutex(Canned())

    static func set(body: Data, chunks: Int, declaresLength: Bool) {
        state.withLock { $0 = Canned(body: body, chunks: chunks, declaresLength: declaresLength) }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let canned = Self.state.withLock { $0 }
        var headers = ["Content-Type": "application/octet-stream"]
        if canned.declaresLength { headers["Content-Length"] = "\(canned.body.count)" }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let size = max(1, canned.body.count / max(1, canned.chunks))
        var offset = 0
        while offset < canned.body.count {
            let end = min(offset + size, canned.body.count)
            client?.urlProtocol(self, didLoad: canned.body.subdata(in: offset..<end))
            offset = end
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
