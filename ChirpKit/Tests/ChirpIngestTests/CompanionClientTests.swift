import ChirpCore
import Foundation
import XCTest

@testable import ChirpIngest

/// `CompanionClient` against `IngestStubURLProtocol`: the mac-companion-v1 request shapes, the Bearer token, the error
/// sentences, refused redirects, and the YouTube audio file. No real network.
final class CompanionClientTests: XCTestCase {
    private var directory: URL!
    private let token = SecretValue(String(repeating: "t", count: 43))
    private let endpoint = CompanionEndpoint(host: "Studio.local", port: 8765)
    private let link = URL(string: "https://youtu.be/AAAAAAAAAAA")!

    override func setUpWithError() throws {
        directory = try makeTemporaryDirectory()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func client(token: SecretValue? = nil) -> CompanionClient {
        CompanionClient(endpoint: endpoint, token: token ?? self.token) { IngestStubURLProtocol.configuration() }
    }

    private static let healthJSON = """
        {"name": "Parakeet companion", "version": "1.0.0", "api": "mac-companion-v1",
         "features": {"speech": true, "youtubeAudio": true},
         "speech": {"models": ["qwen3-tts-1.7b"], "defaultModel": "qwen3-tts-1.7b"}}
        """

    // MARK: - Health and voices

    func testHealthGoesWithoutTheToken() async throws {
        IngestStubURLProtocol.reset { _ in .text(Self.healthJSON, contentType: "application/json") }
        let health = try await client().health()
        XCTAssertEqual(health.version, "1.0.0")
        XCTAssertEqual(health.features, .init(speech: true, youtubeAudio: true))
        XCTAssertEqual(health.speech?.defaultModel, "qwen3-tts-1.7b")
        let request = try XCTUnwrap(IngestStubURLProtocol.requests.first)
        XCTAssertEqual(request.url.absoluteString, "http://studio.local:8765/v1/companion")
        XCTAssertNil(request.header("Authorization"), "health never carries the pairing token")
    }

    func testSomethingElseAnsweringIsNotACompanion() async {
        IngestStubURLProtocol.reset { _ in .text(#"{"models": []}"#, contentType: "application/json") }
        await assertThrows(CompanionError.notACompanion) { _ = try await self.client().health() }
        IngestStubURLProtocol.reset { _ in
            .text(
                Self.healthJSON.replacingOccurrences(of: "mac-companion-v1", with: "v9"),
                contentType: "application/json")
        }
        await assertThrows(CompanionError.notACompanion) { _ = try await self.client().health() }
    }

    func testVoicesCarryTheBearerToken() async throws {
        IngestStubURLProtocol.reset { _ in
            .text(
                #"{"voices": [{"id": "qwen3-tts-1.7b:Ryan", "name": "Ryan", "detail": "Dynamic male (US)", "#
                    + #""languages": ["en"], "model": "qwen3-tts-1.7b", "supportsStyle": true}]}"#,
                contentType: "application/json")
        }
        let voices = try await client().voices()
        XCTAssertEqual(voices.map(\.id), ["qwen3-tts-1.7b:Ryan"])
        XCTAssertTrue(voices[0].supportsStyle)
        XCTAssertEqual(IngestStubURLProtocol.requests.first?.header("Authorization"), "Bearer " + token.reveal())
    }

    func testWrongTokenIsUnauthorized() async {
        IngestStubURLProtocol.reset { _ in
            .text(#"{"error": {"code": "unauthorized", "message": "wrong"}}"#, status: 401)
        }
        await assertThrows(CompanionError.unauthorized) { _ = try await self.client().voices() }
    }

    func testNoTokenFailsBeforeAnyRequest() async {
        IngestStubURLProtocol.reset { _ in .text("{}") }
        await assertThrows(CompanionError.notPaired) { _ = try await self.client(token: SecretValue("")).voices() }
        XCTAssertTrue(IngestStubURLProtocol.requests.isEmpty)
    }

    func testRedirectIsRefused() async {
        IngestStubURLProtocol.reset { _ in
            IngestStubResponse(status: 302, headers: ["Location": "https://elsewhere.example/v1/voices"], chunks: [])
        }
        await assertThrows(CompanionError.redirectRefused) { _ = try await self.client().voices() }
    }

    // MARK: - YouTube audio

    func testYouTubeAudioSavesTheFileWithTitleAndDuration() async throws {
        let audio = Data(repeating: 7, count: 300_000)
        IngestStubURLProtocol.reset { _ in
            .body(
                audio, contentType: "audio/mp4",
                extraHeaders: [
                    "X-Companion-Title": "A%20Synthetic%20Talk%3A%20%C3%BCn%C3%AFcode%20%26%20more",
                    "X-Companion-Duration-Ms": "61500",
                ])
        }
        let reports = CompanionProgressRecorder()
        let result = try await client().youtubeAudio(url: link, into: directory, fileStem: "source") {
            reports.append($0)
        }
        XCTAssertEqual(result.fileURL, directory.appendingPathComponent("source.m4a"))
        XCTAssertEqual(try Data(contentsOf: result.fileURL), audio)
        XCTAssertEqual(result.title, "A Synthetic Talk: ünïcode & more")
        XCTAssertEqual(result.durationMs, 61_500)
        XCTAssertEqual(result.byteCount, 300_000)
        XCTAssertEqual(reports.last?.bytesReceived, 300_000)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("companion.part").path))

        let request = try XCTUnwrap(IngestStubURLProtocol.requests.first)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.url.absoluteString, "http://studio.local:8765/v1/youtube/audio")
        XCTAssertEqual(request.header("Authorization"), "Bearer " + token.reveal())
        XCTAssertEqual(request.json?["url"] as? String, link.absoluteString)
        XCTAssertEqual(request.json?.count, 1, "only the link is sent")
    }

    func testYouTubeErrorCarriesTheCompanionsSentenceAndLeavesNoFile() async {
        IngestStubURLProtocol.reset { _ in
            .text(
                #"{"error": {"code": "video_unavailable", "message": "This video is unavailable."}}"#, status: 422,
                contentType: "application/json")
        }
        do {
            _ = try await client().youtubeAudio(url: link, into: directory, fileStem: "source") { _ in }
            XCTFail("expected an error")
        } catch let error as CompanionError {
            XCTAssertEqual(
                error, .server(status: 422, code: "video_unavailable", message: "This video is unavailable."))
            XCTAssertEqual(error.errorDescription, "This video is unavailable.")
        } catch {
            XCTFail("unexpected \(error)")
        }
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        XCTAssertEqual(leftovers, [])
    }

    func testYouTubeEmptyAnswerIsAnError() async {
        IngestStubURLProtocol.reset { _ in .body(Data(), contentType: "audio/mp4") }
        await assertThrows(CompanionError.emptyAudio) {
            _ = try await self.client().youtubeAudio(url: self.link, into: self.directory, fileStem: "source") { _ in }
        }
    }

    func testYouTubeRedirectIsRefused() async {
        IngestStubURLProtocol.reset { _ in
            IngestStubResponse(status: 307, headers: ["Location": "https://elsewhere.example/"], chunks: [])
        }
        await assertThrows(CompanionError.redirectRefused) {
            _ = try await self.client().youtubeAudio(url: self.link, into: self.directory, fileStem: "source") { _ in }
        }
    }

    func testUnreachableMacIsWorded() async {
        // Nothing listens on port 9 of this machine: a real, local connection refusal.
        let closed = CompanionClient(endpoint: CompanionEndpoint(host: "127.0.0.1", port: 9), token: token)
        do {
            _ = try await closed.health()
            XCTFail("expected an error")
        } catch let error as CompanionError {
            XCTAssertEqual(error, .unreachable(host: "127.0.0.1"))
            XCTAssertTrue(error.errorDescription?.contains("scripts/companion.sh") == true)
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testInvalidAddressFailsBeforeAnyRequest() async {
        IngestStubURLProtocol.reset { _ in .text("{}") }
        let bad = CompanionClient(endpoint: CompanionEndpoint(host: " ", port: 8765), token: token) {
            IngestStubURLProtocol.configuration()
        }
        await assertThrows(CompanionError.invalidAddress) { _ = try await bad.health() }
        XCTAssertTrue(IngestStubURLProtocol.requests.isEmpty)
    }

    // MARK: - Transport (reviews L2 I2, L1 M7, M8)

    /// The companion speaks plain http: an address off the home network gets neither the token nor the link.
    func testAnAddressOffTheHomeNetworkFailsBeforeAnyRequest() async {
        IngestStubURLProtocol.reset { _ in .text(Self.healthJSON) }
        for host in ["203.0.113.7", "mac.example.com"] {
            let remote = CompanionClient(endpoint: CompanionEndpoint(host: host), token: token) {
                IngestStubURLProtocol.configuration()
            }
            await assertThrows(CompanionError.notHomeNetwork) { _ = try await remote.health() }
            await assertThrows(CompanionError.notHomeNetwork) { _ = try await remote.voices() }
            await assertThrows(CompanionError.notHomeNetwork) {
                _ = try await remote.youtubeAudio(url: self.link, into: self.directory, fileStem: "source") { _ in }
            }
        }
        XCTAssertTrue(IngestStubURLProtocol.requests.isEmpty, "nothing left the phone")
        XCTAssertTrue(CompanionError.notHomeNetwork.errorDescription?.contains("home network") == true)
    }

    func testAnAnswerThatIsNotAudioIsNotSaved() async {
        IngestStubURLProtocol.reset { _ in .text("<html>router login</html>", contentType: "text/html") }
        await assertThrows(CompanionError.notAudio) {
            _ = try await self.client().youtubeAudio(url: self.link, into: self.directory, fileStem: "source") { _ in }
        }
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        XCTAssertEqual(leftovers, [], "the page is not kept as source audio")
    }

    func testTheCompanionsErrorSentenceIsCapped() async {
        let long = String(repeating: "Synthetic words. ", count: 400)
        IngestStubURLProtocol.reset { _ in
            .text(
                #"{"error": {"code": "youtube_failed", "message": "\#(long)"}}"#, status: 502,
                contentType: "application/json")
        }
        do {
            _ = try await client().youtubeAudio(url: link, into: directory, fileStem: "source") { _ in }
            XCTFail("expected an error")
        } catch let error as CompanionError {
            XCTAssertLessThanOrEqual(error.errorDescription?.count ?? 0, 301)
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testPlainHTTPBlockedByIOSSaysWhichAddressFormsWork() {
        let error = CompanionClient.mapped(URLError(.appTransportSecurityRequiresSecureConnection), host: "studio.lan")
        XCTAssertEqual(error as? CompanionError, .insecureAddressBlocked(host: "studio.lan"))
        XCTAssertTrue(
            CompanionError.insecureAddressBlocked(host: "studio.lan").errorDescription?.contains(".local") == true)
        XCTAssertTrue(
            CompanionError.unreachable(host: "studio.local").errorDescription?.contains("Local Network") == true,
            "a denied Local Network permission looks the same, so the sentence names it")
    }

    // MARK: - Helpers

    private func assertThrows(
        _ expected: CompanionError, file: StaticString = #filePath, line: UInt = #line,
        _ body: () async throws -> Void
    ) async {
        do {
            try await body()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch let error as CompanionError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("unexpected \(error)", file: file, line: line)
        }
    }
}

/// Collects progress reports from any thread.
private final class CompanionProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var reports: [DownloadProgress] = []

    func append(_ report: DownloadProgress) {
        lock.withLock { reports.append(report) }
    }

    var last: DownloadProgress? {
        lock.withLock { reports.last }
    }
}
