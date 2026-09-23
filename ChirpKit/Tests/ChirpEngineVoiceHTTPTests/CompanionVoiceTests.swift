import ChirpCore
import Foundation
import Synchronization
import XCTest

@testable import ChirpEngineVoiceHTTP

/// A companion configuration the test can change between calls.
final class MutableCompanionConfiguration: CompanionConfiguration, Sendable {
    private let state: Mutex<(CompanionEndpoint?, SecretValue?)>

    init(_ endpoint: CompanionEndpoint?, token: SecretValue?) {
        state = Mutex((endpoint, token))
    }

    func set(_ endpoint: CompanionEndpoint?, token: SecretValue?) {
        state.withLock { $0 = (endpoint, token) }
    }

    func companionEndpoint() -> CompanionEndpoint? { state.withLock { $0.0 } }
    func companionPairingToken() throws -> SecretValue? { state.withLock { $0.1 } }
}

/// A clock the test moves by hand.
final class TestClock: Sendable {
    private let value = Mutex(Date(timeIntervalSince1970: 1_000_000))
    var now: Date { value.withLock { $0 } }
    func advance(_ seconds: TimeInterval) { value.withLock { $0 += seconds } }
}

final class CompanionVoiceTests: XCTestCase {
    /// Synthetic pairing token; never a real one.
    private let token = SecretValue("pairing-TESTTOKEN-0123456789abcdef")
    private let wav = Data("RIFF\u{0}\u{0}\u{0}\u{0}WAVEfmt ".utf8)
    private let healthy =
        #"{"name":"Parakeet companion","version":"1.0.0","api":"mac-companion-v1","features":{"speech":true,"youtubeAudio":true},"speech":{"models":["qwen3-tts-1.7b","kokoro-82m"],"defaultModel":"qwen3-tts-1.7b"}}"#

    private func engine(
        _ configuration: any CompanionConfiguration, clock: TestClock = TestClock(),
        format: SynthesizedAudio.Format = .wav
    ) -> CompanionVoice {
        CompanionVoice(
            configuration: configuration,
            transport: VoiceHTTPTransport(configuration: StubURLProtocol.configuration()),
            responseFormat: format,
            now: { clock.now })
    }

    private func configured(host: String = "studio.local", trusted: Bool = false) -> MutableCompanionConfiguration {
        MutableCompanionConfiguration(
            CompanionEndpoint(host: host, port: 8765, isTrustedForClinicalText: trusted), token: token)
    }

    // MARK: - Speech

    func testSpeechRequestFollowsTheContract() async throws {
        StubURLProtocol.reset { [wav] _ in .audio(wav, contentType: "audio/wav") }
        let audio = try await engine(configured()).synthesize(
            SynthesisRequest(
                text: "Synthetic sentence.", voiceID: "qwen3-tts-1.7b:Ryan", style: "  calm and slow ",
                language: "en", previousText: "Before.", nextText: "After.", privacyClass: .personal))
        XCTAssertEqual(audio, SynthesizedAudio(data: wav, format: .wav))

        let sent = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(sent.url.absoluteString, "http://studio.local:8765/v1/audio/speech")
        XCTAssertEqual(sent.method, "POST")
        XCTAssertEqual(sent.headers["Authorization"], "Bearer \(token.reveal())")
        let json = try XCTUnwrap(sent.json)
        XCTAssertEqual(json["model"] as? String, "qwen3-tts-1.7b")
        XCTAssertEqual(json["voice"] as? String, "Ryan")
        XCTAssertEqual(json["input"] as? String, "Synthetic sentence.")
        XCTAssertEqual(json["instructions"] as? String, "calm and slow")
        XCTAssertEqual(json["response_format"] as? String, "wav")
        XCTAssertEqual(json["language"] as? String, "en")
        XCTAssertNil(json["previousText"])
        XCTAssertNil(json["nextText"])
    }

    func testPlainVoiceNameUsesTheDefaultModelAndEmptyStyleIsOmitted() async throws {
        StubURLProtocol.reset { [wav] _ in .audio(wav, contentType: "audio/wav") }
        _ = try await engine(configured()).synthesize(
            SynthesisRequest(text: "Hi.", voiceID: "af_heart", style: "   ", privacyClass: .general))
        let json = try XCTUnwrap(StubURLProtocol.requests.first?.json)
        XCTAssertNil(json["model"])
        XCTAssertEqual(json["voice"] as? String, "af_heart")
        XCTAssertNil(json["instructions"])
        XCTAssertNil(json["language"])
    }

    func testTheContentTypeDecidesTheFormat() async throws {
        StubURLProtocol.reset { [wav] _ in .audio(wav, contentType: "audio/mpeg") }
        let audio = try await engine(configured(), format: .mp3).synthesize(
            SynthesisRequest(text: "Hi.", voiceID: "Ryan", privacyClass: .general))
        XCTAssertEqual(audio.format, .mp3)
        XCTAssertEqual(StubURLProtocol.requests.first?.json?["response_format"] as? String, "mp3")
    }

    func testErrorMapping() async throws {
        let cases: [(Int, String, SpeechSynthesisError)] = [
            (401, #"{"error":{"code":"unauthorized","message":"Wrong token"}}"#, .unauthorized),
            (
                400, #"{"error":{"code":"unknown_voice","message":"No voice Zed"}}"#,
                .unsupportedVoice("qwen3-tts-1.7b:Zed")
            ),
            (
                400, #"{"error":{"code":"bad_request","message":"Malformed body"}}"#,
                .server(status: 400, message: "Malformed body")
            ),
            (
                413, #"{"error":{"code":"too_long","message":"input over 4000"}}"#,
                .server(status: 413, message: "The text is too long for the Mac companion.")
            ),
            (
                503,
                #"{"error":{"code":"model_not_loaded","message":"Run: parakeet-companion --load qwen3-tts-1.7b"}}"#,
                .server(status: 503, message: "Run: parakeet-companion --load qwen3-tts-1.7b")
            ),
        ]
        for (status, body, expected) in cases {
            StubURLProtocol.reset { _ in .body(body, status: status) }
            do {
                _ = try await engine(configured()).synthesize(
                    SynthesisRequest(text: "Hi.", voiceID: "qwen3-tts-1.7b:Zed", privacyClass: .general))
                XCTFail("\(status) must throw")
            } catch let error as SpeechSynthesisError {
                XCTAssertEqual(error, expected, "status \(status)")
            }
        }
    }

    func testTheTokenNeverAppearsInAnError() async throws {
        let raw = token.reveal()
        StubURLProtocol.reset { _ in .body(#"{"detail":"token \#(raw) rejected"}"#, status: 500) }
        do {
            _ = try await engine(configured()).synthesize(
                SynthesisRequest(text: "Hi.", voiceID: "Ryan", privacyClass: .general))
            XCTFail("500 must throw")
        } catch let error as SpeechSynthesisError {
            XCTAssertFalse("\(error) \(error.errorDescription ?? "")".contains(raw))
        }
    }

    func testRedirectIsRefused() async throws {
        StubURLProtocol.reset { request in
            request.url.host == "studio.local"
                ? StubResponse(redirectTo: URL(string: "https://cloud.example/v1/audio/speech")) : .audio(Data([1]))
        }
        do {
            _ = try await engine(configured(trusted: true)).synthesize(
                SynthesisRequest(text: "Clinical synthetic.", voiceID: "Ryan", privacyClass: .clinical))
            XCTFail("a redirect must be refused")
        } catch let error as SpeechSynthesisError {
            XCTAssertEqual(error, .redirectRefused)
        }
        XCTAssertEqual(StubURLProtocol.requests.map(\.url.host), ["studio.local"])
    }

    func testEmptyAudioAndNotConfiguredSendNothingUseful() async throws {
        StubURLProtocol.reset { _ in .audio(Data(), contentType: "audio/wav") }
        do {
            _ = try await engine(configured()).synthesize(
                SynthesisRequest(text: "Hi.", voiceID: "Ryan", privacyClass: .general))
            XCTFail("empty audio must throw")
        } catch let error as SpeechSynthesisError {
            XCTAssertEqual(error, .emptyAudio)
        }

        StubURLProtocol.reset { [wav] _ in .audio(wav) }
        for configuration in [
            MutableCompanionConfiguration(nil, token: token),
            MutableCompanionConfiguration(CompanionEndpoint(host: "studio.local"), token: nil),
        ] {
            do {
                _ = try await engine(configuration).synthesize(
                    SynthesisRequest(text: "Hi.", voiceID: "Ryan", privacyClass: .general))
                XCTFail("not configured must throw")
            } catch let error as SpeechSynthesisError {
                XCTAssertEqual(error.kindName, "not_configured")
            }
        }
        XCTAssertTrue(StubURLProtocol.requests.isEmpty)
    }

    // MARK: - Voices

    func testVoiceListParsing() async throws {
        StubURLProtocol.reset { _ in
            .body(
                #"{"voices":[{"id":"qwen3-tts-1.7b:Ryan","name":"Ryan","detail":"Dynamic male, strong rhythmic drive (US)","languages":["en"],"model":"qwen3-tts-1.7b","supportsStyle":true},{"id":"kokoro-82m:af_heart","name":"Heart"}]}"#
            )
        }
        let voices = try await engine(configured()).voices()
        XCTAssertEqual(
            voices,
            [
                SynthesisVoice(
                    id: "qwen3-tts-1.7b:Ryan", name: "Ryan", detail: "Dynamic male, strong rhythmic drive (US)",
                    languages: ["en"]),
                SynthesisVoice(id: "kokoro-82m:af_heart", name: "Heart"),
            ])
        let sent = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(sent.url.absoluteString, "http://studio.local:8765/v1/voices")
        XCTAssertEqual(sent.headers["Authorization"], "Bearer \(token.reveal())")

        StubURLProtocol.reset { _ in .body(#"{"error":{"code":"unauthorized","message":"no"}}"#, status: 401) }
        do {
            _ = try await engine(configured()).voices()
            XCTFail("401 must throw")
        } catch let error as SpeechSynthesisError {
            XCTAssertEqual(error, .unauthorized)
        }
    }

    // MARK: - Availability

    func testAvailabilityIsCachedForThirtySeconds() async throws {
        let healthy = self.healthy
        StubURLProtocol.reset { _ in .body(healthy) }
        let clock = TestClock()
        let voice = engine(configured(), clock: clock)

        let first = await voice.availability()
        XCTAssertEqual(first, .available)
        clock.advance(29)
        _ = await voice.availability()
        XCTAssertEqual(StubURLProtocol.requests.count, 1, "reused within 30 s")
        let health = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(health.url.absoluteString, "http://studio.local:8765/v1/companion")
        XCTAssertNil(health.headers["Authorization"], "health needs no token")

        clock.advance(2)
        _ = await voice.availability()
        XCTAssertEqual(StubURLProtocol.requests.count, 2, "asked again after 30 s")

        voice.invalidateAvailability()
        _ = await voice.availability()
        XCTAssertEqual(StubURLProtocol.requests.count, 3, "Check again asks at once")
    }

    func testAvailabilityStates() async throws {
        StubURLProtocol.reset { _ in .body("{}") }
        guard
            case .unavailable(let notSetUp) = await engine(MutableCompanionConfiguration(nil, token: nil))
                .availability()
        else { return XCTFail("not set up") }
        XCTAssertTrue(notSetUp.contains("Settings → Mac companion"), notSetUp)

        guard
            case .unavailable(let notPaired) = await engine(
                MutableCompanionConfiguration(CompanionEndpoint(host: "studio.local"), token: nil)
            ).availability()
        else { return XCTFail("not paired") }
        XCTAssertTrue(notPaired.contains("Pair"), notPaired)
        XCTAssertTrue(StubURLProtocol.requests.isEmpty, "no network before the companion is set up and paired")

        StubURLProtocol.reset { _ in StubResponse(failure: URLError(.cannotConnectToHost)) }
        guard case .unavailable(let unreachable) = await engine(configured()).availability() else {
            return XCTFail("unreachable")
        }
        XCTAssertTrue(unreachable.contains("not reachable at studio.local"), unreachable)

        StubURLProtocol.reset { _ in
            .body(#"{"name":"Parakeet companion","api":"mac-companion-v1","features":{"speech":false}}"#)
        }
        guard case .unavailable(let noModel) = await engine(configured()).availability() else {
            return XCTFail("no model")
        }
        XCTAssertTrue(noModel.contains("no voice model"), noModel)

        StubURLProtocol.reset { _ in .body("<html>router login</html>", contentType: "text/html") }
        guard case .unavailable(let notCompanion) = await engine(configured()).availability() else {
            return XCTFail("not a companion")
        }
        XCTAssertTrue(notCompanion.contains("Parakeet companion"), notCompanion)
    }

    /// Review L2 I2: the companion speaks plain http, so it must be on the home network. An internet address gets
    /// neither text nor the pairing token (not even the health check goes out).
    func testAnAddressOffTheHomeNetworkIsRefusedAndNothingIsSent() async throws {
        StubURLProtocol.reset { [wav] _ in .audio(wav, contentType: "audio/wav") }
        for host in ["203.0.113.7", "voices.example.com", "100.64.1.2"] {
            let voice = engine(configured(host: host, trusted: true))
            guard case .unavailable(let sentence) = await voice.availability() else {
                return XCTFail("\(host) must be unavailable")
            }
            XCTAssertEqual(sentence, CompanionVoice.notHomeNetworkMessage)
            do {
                _ = try await voice.synthesize(SynthesisRequest(text: "Hi.", voiceID: "Ryan", privacyClass: .general))
                XCTFail("an internet companion must not receive text")
            } catch let error as SpeechSynthesisError {
                XCTAssertEqual(error.kindName, "not_configured")
                XCTAssertTrue(error.errorDescription?.contains("home network") == true)
            }
            do {
                _ = try await voice.voices()
                XCTFail("an internet companion must not receive the token")
            } catch {}
            XCTAssertThrowsError(try voice.pinned())
        }
        XCTAssertTrue(StubURLProtocol.requests.isEmpty, "nothing left the phone")
    }

    func testStatusReportsModels() async throws {
        let healthy = self.healthy
        StubURLProtocol.reset { _ in .body(healthy) }
        let status = try await engine(configured()).status()
        XCTAssertEqual(status.version, "1.0.0")
        XCTAssertEqual(status.api, "mac-companion-v1")
        XCTAssertTrue(status.speech)
        XCTAssertEqual(status.models, ["qwen3-tts-1.7b", "kokoro-82m"])
    }

    // MARK: - Routing inputs

    func testDescriptorAndHostFollowTheConfiguration() {
        let configuration = configured(host: " Studio.LOCAL. ")
        let voice = engine(configuration)
        XCTAssertEqual(voice.descriptor.id, "companion.speech")
        XCTAssertEqual(voice.descriptor.kind, .speechSynthesis)
        XCTAssertEqual(voice.descriptor.locality, .localNetwork)
        XCTAssertEqual(voice.endpointHost, "studio.local")
        XCTAssertEqual(voice.maxCharactersPerRequest, 4_000)

        configuration.set(CompanionEndpoint(host: "voices.example.com", isTrustedForClinicalText: true), token: token)
        XCTAssertEqual(voice.descriptor.locality, .cloud, "an internet host is never home network")
        XCTAssertEqual(voice.endpointHost, "voices.example.com")
    }

    func testAPinnedEngineKeepsTheHostRoutingApproved() async throws {
        StubURLProtocol.reset { [wav] _ in .audio(wav, contentType: "audio/wav") }
        let configuration = configured(host: "studio.local", trusted: true)
        let pinned = try engine(configuration).pinned()
        configuration.set(CompanionEndpoint(host: "other.local"), token: SecretValue("other-TOKEN-0000000000"))

        XCTAssertEqual(pinned.endpointHost, "studio.local")
        _ = try await pinned.synthesize(SynthesisRequest(text: "Hi.", voiceID: "Ryan", privacyClass: .general))
        let sent = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(sent.url.host, "studio.local")
        XCTAssertEqual(sent.headers["Authorization"], "Bearer \(token.reveal())")

        XCTAssertThrowsError(try engine(MutableCompanionConfiguration(nil, token: nil)).pinned())
    }

    func testVoiceIDSplitting() {
        XCTAssertTrue(CompanionVoice.split(voiceID: "qwen3-tts-1.7b:Ryan")! == ("qwen3-tts-1.7b", "Ryan"))
        XCTAssertTrue(CompanionVoice.split(voiceID: "Ryan")! == (nil, "Ryan"))
        XCTAssertTrue(CompanionVoice.split(voiceID: ":Ryan")! == (nil, "Ryan"))
        XCTAssertNil(CompanionVoice.split(voiceID: "  "))
        XCTAssertNil(CompanionVoice.split(voiceID: "qwen3:"))
    }
}
