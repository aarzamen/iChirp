import ChirpCore
import Foundation
import Synchronization
import XCTest

@testable import ChirpEngineVoiceHTTP

/// An in-memory `SecretStoring` (tests never touch the Keychain).
final class MemorySecretStore: SecretStoring, Sendable {
    private let values = Mutex<[String: SecretValue]>([:])
    let failsReads: Bool

    init(_ initial: [String: SecretValue] = [:], failsReads: Bool = false) {
        values.withLock { $0 = initial }
        self.failsReads = failsReads
    }

    func secret(forAccount account: String) throws -> SecretValue? {
        if failsReads { throw CocoaError(.fileReadUnknown) }
        return values.withLock { $0[account] }
    }

    func setSecret(_ secret: SecretValue, forAccount account: String) throws {
        values.withLock { $0[account] = secret }
    }

    func deleteSecret(forAccount account: String) throws {
        _ = values.withLock { $0.removeValue(forKey: account) }
    }
}

final class XAIVoiceTests: XCTestCase {
    /// Obviously fake; never a real key.
    private let key = SecretValue("xai-TESTKEY-0123456789abcdef")
    private let mp3 = Data([0xFF, 0xFB, 0x90, 0x44, 0x00, 0x00])

    private func voice(key: SecretValue? = nil, failsReads: Bool = false) -> XAIVoice {
        let store = MemorySecretStore(
            key.map { [XAIVoice.secretAccount: $0] } ?? [:], failsReads: failsReads)
        return XAIVoice(
            secrets: store, transport: VoiceHTTPTransport(configuration: StubURLProtocol.configuration()))
    }

    private func request(_ text: String = "Hello from Parakeet.", voice: String = "eve") -> SynthesisRequest {
        SynthesisRequest(text: text, voiceID: voice, privacyClass: .personal)
    }

    func testDescriptorIsCloudOnTheXAIHost() {
        let engine = voice(key: key)
        XCTAssertEqual(engine.descriptor.id, "xai.tts")
        XCTAssertEqual(engine.descriptor.kind, .speechSynthesis)
        XCTAssertEqual(engine.descriptor.locality, .cloud)
        XCTAssertEqual(engine.endpointHost, "api.x.ai")
        XCTAssertEqual(engine.maxCharactersPerRequest, 15_000)
    }

    func testStockVoicesOnlyNoClonedVoiceIsBuiltIn() async throws {
        let voices = try await voice(key: key).voices()
        XCTAssertEqual(voices.map(\.id), ["eve", "ara", "rex", "sal", "leo"])
    }

    func testSynthesizeSendsTheReadbackRequestShape() async throws {
        let mp3 = self.mp3
        StubURLProtocol.reset { _ in .audio(mp3) }
        let audio = try await voice(key: key).synthesize(
            SynthesisRequest(
                text: "Synthetic sentence one.", voiceID: " ara ", language: "de", previousText: "Before.",
                nextText: "After.", privacyClass: .general))
        XCTAssertEqual(audio, SynthesizedAudio(data: mp3, format: .mp3))

        let sent = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(StubURLProtocol.requests.count, 1)
        XCTAssertEqual(sent.url.absoluteString, "https://api.x.ai/v1/tts")
        XCTAssertEqual(sent.method, "POST")
        XCTAssertEqual(sent.headers["Authorization"], "Bearer \(key.reveal())")
        XCTAssertEqual(sent.headers["Content-Type"], "application/json")
        let json = try XCTUnwrap(sent.json)
        XCTAssertEqual(json["text"] as? String, "Synthetic sentence one.")
        XCTAssertEqual(json["voice_id"] as? String, "ara")
        XCTAssertEqual(json["language"] as? String, "de")
        let format = try XCTUnwrap(json["output_format"] as? [String: Any])
        XCTAssertEqual(format["codec"] as? String, "mp3")
        XCTAssertEqual(format["sample_rate"] as? Int, 44_100)
        XCTAssertEqual(format["bit_rate"] as? Int, 128_000)
        XCTAssertEqual(Set(json.keys), ["text", "voice_id", "language", "output_format"], "neighbours are never sent")
    }

    func testLanguageDefaultsToEnglish() async throws {
        StubURLProtocol.reset { [mp3] _ in .audio(mp3) }
        _ = try await voice(key: key).synthesize(request())
        XCTAssertEqual(StubURLProtocol.requests.first?.json?["language"] as? String, "en")
    }

    func testAClonedVoiceIDTypedOnThePhoneIsSentAsIs() async throws {
        StubURLProtocol.reset { [mp3] _ in .audio(mp3) }
        _ = try await voice(key: key).synthesize(request(voice: "custom-voice-id-typed-by-owner"))
        XCTAssertEqual(StubURLProtocol.requests.first?.json?["voice_id"] as? String, "custom-voice-id-typed-by-owner")
    }

    func testStatusMapping() async throws {
        let cases: [(Int, SpeechSynthesisError)] = [
            (401, .unauthorized), (403, .unauthorized), (429, .rateLimited),
            (500, .server(status: 500, message: "Upstream exploded")),
            (503, .server(status: 503, message: "Upstream exploded")),
        ]
        for (status, expected) in cases {
            StubURLProtocol.reset { _ in .body(#"{"error":{"message":"Upstream exploded"}}"#, status: status) }
            do {
                _ = try await voice(key: key).synthesize(request())
                XCTFail("\(status) must throw")
            } catch let error as SpeechSynthesisError {
                XCTAssertEqual(error, expected, "status \(status)")
            }
        }
    }

    func testEmptyAudioIsAnError() async throws {
        StubURLProtocol.reset { _ in .audio(Data()) }
        do {
            _ = try await voice(key: key).synthesize(request())
            XCTFail("empty audio must throw")
        } catch let error as SpeechSynthesisError {
            XCTAssertEqual(error, .emptyAudio)
        }
    }

    func testRedirectIsRefusedAndNothingReachesTheOtherHost() async throws {
        StubURLProtocol.reset { request in
            request.url.host == "api.x.ai"
                ? StubResponse(redirectTo: URL(string: "https://evil.example/tts")) : .audio(Data([1]))
        }
        do {
            _ = try await voice(key: key).synthesize(request())
            XCTFail("a redirect must be refused")
        } catch let error as SpeechSynthesisError {
            XCTAssertEqual(error, .redirectRefused)
        }
        XCTAssertEqual(StubURLProtocol.requests.map(\.url.host), ["api.x.ai"])
    }

    func testTheKeyNeverAppearsInAnError() async throws {
        let raw = key.reveal()
        StubURLProtocol.reset { _ in
            .body(
                #"{"error":{"message":"bad request for key \#(raw) with Bearer \#(raw) and xai-OTHERKEY-99999999"}}"#,
                status: 400)
        }
        do {
            _ = try await voice(key: key).synthesize(request())
            XCTFail("400 must throw")
        } catch let error as SpeechSynthesisError {
            let text = "\(error) \(error.errorDescription ?? "")"
            XCTAssertFalse(text.contains(raw), text)
            XCTAssertFalse(text.contains("xai-OTHERKEY"), text)
            XCTAssertEqual(error.kindName, "server")
        }
    }

    func testMissingKeySendsNothing() async throws {
        StubURLProtocol.reset { [mp3] _ in .audio(mp3) }
        let engine = voice(key: nil)
        guard case .unavailable(let sentence) = await engine.availability() else {
            return XCTFail("no key must be unavailable")
        }
        XCTAssertTrue(sentence.contains("Settings → Voices"), sentence)
        do {
            _ = try await engine.synthesize(request())
            XCTFail("no key must throw")
        } catch let error as SpeechSynthesisError {
            XCTAssertEqual(error.kindName, "not_configured")
        }
        XCTAssertTrue(StubURLProtocol.requests.isEmpty)
    }

    func testUnreadableKeychainIsNotConfigured() async {
        guard case .unavailable = await voice(key: key, failsReads: true).availability() else {
            return XCTFail("an unreadable key must be unavailable")
        }
    }

    func testAvailabilityWithAKeyNeedsNoNetwork() async {
        StubURLProtocol.reset { _ in .body("{}", status: 500) }
        let availability = await voice(key: key).availability()
        XCTAssertEqual(availability, .available)
        XCTAssertTrue(StubURLProtocol.requests.isEmpty)
    }

    func testEmptyVoiceAndOverlongTextSendNothing() async throws {
        StubURLProtocol.reset { [mp3] _ in .audio(mp3) }
        let engine = voice(key: key)
        do {
            _ = try await engine.synthesize(request(voice: "  "))
            XCTFail("an empty voice must throw")
        } catch let error as SpeechSynthesisError {
            XCTAssertEqual(error.kindName, "not_configured")
        }
        do {
            _ = try await engine.synthesize(request(String(repeating: "a", count: 15_001)))
            XCTFail("overlong text must throw")
        } catch let error as SpeechSynthesisError {
            XCTAssertEqual(error.kindName, "server")
        }
        XCTAssertTrue(StubURLProtocol.requests.isEmpty)
    }

    func testValidateKeyCallsTheKeyEndpointWithoutText() async throws {
        StubURLProtocol.reset { _ in .body(#"{"api_key_id":"synthetic"}"#) }
        try await voice(key: key).validateKey()
        let sent = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(sent.url.absoluteString, "https://api.x.ai/v1/api-key")
        XCTAssertEqual(sent.method, "GET")
        XCTAssertTrue(sent.body.isEmpty)
        XCTAssertEqual(sent.headers["Authorization"], "Bearer \(key.reveal())")

        StubURLProtocol.reset { _ in .body(#"{"error":"Incorrect API key"}"#, status: 401) }
        do {
            try await voice(key: key).validateKey()
            XCTFail("401 must throw")
        } catch let error as SpeechSynthesisError {
            XCTAssertEqual(error, .unauthorized)
        }
    }

    func testCancellationStaysCancellation() {
        XCTAssertTrue(VoiceHTTPTransport.map(URLError(.cancelled)) is CancellationError)
        XCTAssertEqual(
            VoiceHTTPTransport.map(URLError(.cannotConnectToHost)) as? SpeechSynthesisError,
            .connectionFailed(URLError(.cannotConnectToHost).localizedDescription))
    }

    func testMessageShapes() {
        XCTAssertEqual(
            VoiceHTTPErrors.message(from: Data(#"{"detail":"Model not loaded"}"#.utf8), secret: nil), "Model not loaded"
        )
        XCTAssertEqual(VoiceHTTPErrors.message(from: Data(#"{"error":"plain"}"#.utf8), secret: nil), "plain")
        XCTAssertEqual(VoiceHTTPErrors.message(from: Data("  gateway down \n".utf8), secret: nil), "gateway down")
        XCTAssertEqual(
            VoiceHTTPErrors.code(from: Data(#"{"error":{"code":"unknown_voice","message":"x"}}"#.utf8)),
            "unknown_voice")
    }
}
