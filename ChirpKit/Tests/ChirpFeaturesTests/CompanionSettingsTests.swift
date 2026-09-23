import ChirpCore
import ChirpIngest
import Foundation
import Synchronization
import XCTest

@testable import ChirpFeatures

/// Answers for `CompanionSettingsStubProtocol`: by path, else 404. No real network.
final class CompanionSettingsStubProtocol: URLProtocol, @unchecked Sendable {
    struct Answer: Sendable {
        var status: Int
        var body: String
    }

    private static let answers = Mutex<[String: Answer]>([:])
    private static let seen = Mutex<[URLRequest]>([])

    static func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CompanionSettingsStubProtocol.self]
        return configuration
    }

    static func reset(_ answers: [String: Answer]) {
        self.answers.withLock { $0 = answers }
        seen.withLock { $0 = [] }
    }

    static var requests: [URLRequest] { seen.withLock { $0 } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.seen.withLock { $0.append(request) }
        let answer = Self.answers.withLock { $0[request.url?.path ?? ""] } ?? Answer(status: 404, body: "{}")
        let response = HTTPURLResponse(
            url: request.url!, statusCode: answer.status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(answer.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class CompanionSettingsStoreTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!
    private let secrets = FakeSecretStore()

    override func setUp() {
        suiteName = "CompanionSettingsStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private var store: CompanionSettingsStore { CompanionSettingsStore(defaults: defaults, secrets: secrets) }

    func testNothingSetUpMeansNoEndpointAndNoClient() throws {
        XCTAssertNil(store.companionEndpoint())
        XCTAssertNil(try store.companionPairingToken())
        XCTAssertNil(store.makeClient())
    }

    func testSaveKeepsTheTokenOnlyInTheSecretStore() throws {
        let token = String(repeating: "k", count: 43)
        try store.save(
            CompanionEndpoint(host: " studio.local ", port: 8766, isTrustedForClinicalText: true),
            token: .set(SecretValue(token)))
        XCTAssertEqual(
            store.companionEndpoint(),
            CompanionEndpoint(host: "studio.local", port: 8766, isTrustedForClinicalText: true))
        XCTAssertEqual(try store.companionPairingToken()?.reveal(), token)
        XCTAssertEqual(secrets.accounts, [CompanionSettingsStore.tokenAccount])
        let blob = try XCTUnwrap(defaults.data(forKey: CompanionSettingsStore.key))
        XCTAssertFalse(String(decoding: blob, as: UTF8.self).contains(token), "the token never lands in UserDefaults")
        XCTAssertEqual(store.makeClient()?.endpoint.baseURL?.absoluteString, "http://studio.local:8766")

        try store.save(CompanionEndpoint(host: "studio.local"), token: .keep)
        XCTAssertEqual(try store.companionPairingToken()?.reveal(), token, "keep leaves the token")
    }

    func testRemoveForgetsEverything() throws {
        try store.save(CompanionEndpoint(host: "studio.local"), token: .set(SecretValue("t")))
        try store.remove()
        XCTAssertNil(store.companionEndpoint())
        XCTAssertTrue(secrets.accounts.isEmpty)
    }

    func testAKeychainFailureChangesNothing() throws {
        secrets.setFailWrites(true)
        XCTAssertThrowsError(try store.save(CompanionEndpoint(host: "studio.local"), token: .set(SecretValue("t"))))
        XCTAssertNil(store.companionEndpoint())
    }

    func testRoutingTrustsOnlyATrustedHomeNetworkMac() throws {
        try store.save(CompanionEndpoint(host: "Studio.local", isTrustedForClinicalText: true), token: .keep)
        XCTAssertEqual(store.routingPolicy().trustedLocalNetworkHosts, ["studio.local"])
        let base = PrivacyRoutingPolicy(trustedLocalNetworkHosts: ["ollama.local"])
        XCTAssertEqual(store.routingPolicy(adding: base).trustedLocalNetworkHosts, ["ollama.local", "studio.local"])

        try store.save(CompanionEndpoint(host: "studio.local", isTrustedForClinicalText: false), token: .keep)
        XCTAssertTrue(store.routingPolicy().trustedLocalNetworkHosts.isEmpty)

        try store.save(CompanionEndpoint(host: "companion.example.com", isTrustedForClinicalText: true), token: .keep)
        XCTAssertTrue(store.routingPolicy().trustedLocalNetworkHosts.isEmpty, "an internet address is never trusted")
    }

    func testAddressParsing() throws {
        XCTAssertEqual(
            try CompanionAddress.parse(host: "studio.local", port: "", trusted: false),
            CompanionEndpoint(host: "studio.local", port: 8765))
        XCTAssertEqual(
            try CompanionAddress.parse(host: "studio.local:9000", port: "", trusted: true),
            CompanionEndpoint(host: "studio.local", port: 9000, isTrustedForClinicalText: true))
        XCTAssertEqual(
            try CompanionAddress.parse(host: "http://192.168.1.20:8765/v1/companion", port: "", trusted: false),
            CompanionEndpoint(host: "192.168.1.20", port: 8765))
        XCTAssertEqual(
            try CompanionAddress.parse(host: "192.168.1.20", port: " 8800 ", trusted: false).port, 8800)
        XCTAssertEqual(try CompanionAddress.parse(host: "fe80::1", port: "", trusted: false).host, "fe80::1")
        XCTAssertThrowsError(try CompanionAddress.parse(host: "", port: "", trusted: false)) {
            XCTAssertEqual($0 as? CompanionAddress.ParseError, .missingHost)
        }
        XCTAssertThrowsError(try CompanionAddress.parse(host: "https://studio.local", port: "", trusted: false)) {
            XCTAssertEqual($0 as? CompanionAddress.ParseError, .notHTTP)
        }
        XCTAssertThrowsError(try CompanionAddress.parse(host: "studio.local", port: "abc", trusted: false)) {
            XCTAssertEqual($0 as? CompanionAddress.ParseError, .invalidPort)
        }
        XCTAssertThrowsError(try CompanionAddress.parse(host: "studio.local", port: "70000", trusted: false)) {
            XCTAssertEqual($0 as? CompanionAddress.ParseError, .invalidPort)
        }
        XCTAssertThrowsError(try CompanionAddress.parse(host: "my mac", port: "", trusted: false))
        // Review L2 I2: plain http never crosses the internet, so only home-network addresses are accepted.
        for internet in ["companion.example.com", "203.0.113.7", "http://8.8.8.8:8765", "100.64.1.2"] {
            XCTAssertThrowsError(try CompanionAddress.parse(host: internet, port: "", trusted: false), internet) {
                XCTAssertEqual($0 as? CompanionAddress.ParseError, .notHomeNetwork)
            }
        }
        XCTAssertTrue(CompanionAddress.ParseError.notHomeNetwork.errorDescription?.contains("home network") == true)
    }
}

@MainActor
final class CompanionSettingsViewModelTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!
    private let secrets = FakeSecretStore()
    private let token = String(repeating: "t", count: 43)

    override func setUp() async throws {
        suiteName = "CompanionSettingsViewModelTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func makeModel() -> CompanionSettingsViewModel {
        CompanionSettingsViewModel(store: CompanionSettingsStore(defaults: defaults, secrets: secrets)) {
            CompanionClient(endpoint: $0, token: $1) { CompanionSettingsStubProtocol.configuration() }
        }
    }

    func testANewFormStartsEmptyWithTheDefaultPort() {
        let model = makeModel()
        XCTAssertFalse(model.isConfigured)
        XCTAssertEqual(model.host, "")
        XCTAssertEqual(model.port, "8765")
        XCTAssertFalse(model.hasSavedToken)
        XCTAssertFalse(model.hasUnsavedChanges)
    }

    func testSaveNeedsATokenTheFirstTimeAndNeverShowsItAgain() {
        let model = makeModel()
        model.host = "studio.local"
        XCTAssertTrue(model.hasUnsavedChanges)
        XCTAssertFalse(model.save())
        XCTAssertEqual(model.errorMessage, "Enter the pairing token the companion printed on your Mac.")

        model.newToken = token
        model.isTrusted = true
        XCTAssertTrue(model.save())
        XCTAssertTrue(model.isConfigured)
        XCTAssertTrue(model.hasSavedToken)
        XCTAssertEqual(model.newToken, "", "the saved token is never read back into the form")
        XCTAssertTrue(model.isTrusted)

        model.port = "8766"
        XCTAssertTrue(model.save(), "an empty token field keeps the saved one")
        XCTAssertEqual(try? secrets.secret(forAccount: CompanionSettingsStore.tokenAccount)?.reveal(), token)
    }

    func testAnInternetAddressIsRefusedWithASentence() {
        let model = makeModel()
        model.host = "companion.example.com"
        model.newToken = token
        model.isTrusted = true
        XCTAssertTrue(model.isInternetAddress)
        XCTAssertFalse(model.save(), "the companion must be on the home network")
        XCTAssertEqual(model.errorMessage, CompanionAddress.ParseError.notHomeNetwork.errorDescription)
        XCTAssertFalse(model.isConfigured)
        XCTAssertTrue(secrets.accounts.isEmpty, "no token stored for it")

        CompanionSettingsStubProtocol.reset([:])
        model.testConnection()
        XCTAssertEqual(model.testState, .failed(CompanionAddress.ParseError.notHomeNetwork.errorDescription!))
        XCTAssertTrue(CompanionSettingsStubProtocol.requests.isEmpty, "Test connection sends nothing either")
    }

    /// Review L1 M3: Test connection sends the saved token only to the saved address; a typed, unsaved address needs
    /// the token typed too.
    func testTestConnectionNeverSendsTheSavedTokenToAnUnsavedAddress() async {
        CompanionSettingsStubProtocol.reset([
            "/v1/companion": .init(
                status: 200,
                body: #"{"name": "Parakeet companion", "version": "1.0.0", "api": "mac-companion-v1", "#
                    + #""features": {"speech": true, "youtubeAudio": false}}"#),
            "/v1/voices": .init(status: 200, body: #"{"voices": []}"#),
        ])
        let model = makeModel()
        model.host = "studio.local"
        model.newToken = token
        XCTAssertTrue(model.save())

        for (host, port) in [("other-mac.local", "8765"), ("studio.local", "9000")] {
            CompanionSettingsStubProtocol.reset([
                "/v1/companion": .init(
                    status: 200,
                    body: #"{"name": "Parakeet companion", "version": "1.0.0", "api": "mac-companion-v1", "#
                        + #""features": {"speech": true, "youtubeAudio": false}}"#),
                "/v1/voices": .init(status: 200, body: #"{"voices": []}"#),
            ])
            model.host = host
            model.port = port
            model.testConnection()
            await model.waitForTest()
            let requests = CompanionSettingsStubProtocol.requests
            XCTAssertTrue(
                requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == nil },
                "the saved token never goes to \(host):\(port)")
            guard case .failed(let message) = model.testState else { return XCTFail("\(model.testState)") }
            XCTAssertTrue(message.contains("Type the pairing token"), message)
        }

        // Back to the saved address: the saved token is used.
        model.host = "studio.local"
        model.port = "8765"
        CompanionSettingsStubProtocol.reset([
            "/v1/companion": .init(
                status: 200,
                body: #"{"name": "Parakeet companion", "version": "1.0.0", "api": "mac-companion-v1", "#
                    + #""features": {"speech": true, "youtubeAudio": false}}"#),
            "/v1/voices": .init(status: 200, body: #"{"voices": []}"#),
        ])
        model.testConnection()
        await model.waitForTest()
        XCTAssertEqual(
            CompanionSettingsStubProtocol.requests.last?.value(forHTTPHeaderField: "Authorization"), "Bearer \(token)")
    }

    func testRemoveClearsTheForm() {
        let model = makeModel()
        model.host = "studio.local"
        model.newToken = token
        XCTAssertTrue(model.save())
        model.remove()
        XCTAssertFalse(model.isConfigured)
        XCTAssertEqual(model.host, "")
        XCTAssertTrue(secrets.accounts.isEmpty)
    }

    func testTestConnectionReportsWhatTheMacOffers() async {
        CompanionSettingsStubProtocol.reset([
            "/v1/companion": .init(
                status: 200,
                body: #"{"name": "Parakeet companion", "version": "1.0.0", "api": "mac-companion-v1", "#
                    + #""features": {"speech": true, "youtubeAudio": true}, "#
                    + #""speech": {"models": ["qwen3-tts-1.7b"], "defaultModel": "qwen3-tts-1.7b"}}"#),
            "/v1/voices": .init(
                status: 200,
                body: #"{"voices": [{"id": "qwen3-tts-1.7b:Ryan", "name": "Ryan", "detail": "d", "languages": ["en"], "#
                    + #""model": "qwen3-tts-1.7b", "supportsStyle": true}]}"#),
        ])
        let model = makeModel()
        model.host = "studio.local"
        model.newToken = token
        model.testConnection()
        XCTAssertEqual(model.testState, .testing)
        await model.waitForTest()
        XCTAssertEqual(
            model.testState,
            .succeeded(
                summary: "Connected to Parakeet companion 1.0.0",
                details: ["Voices: qwen3-tts-1.7b", "1 voice available", "YouTube audio: ready"]))
        XCTAssertFalse(model.isConfigured, "testing does not save")
        let requests = CompanionSettingsStubProtocol.requests
        XCTAssertNil(requests.first?.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(requests.last?.value(forHTTPHeaderField: "Authorization"), "Bearer \(token)")
    }

    func testTestConnectionSaysWhyYouTubeAudioIsOff() async {
        CompanionSettingsStubProtocol.reset([
            "/v1/companion": .init(
                status: 200,
                body: #"{"name": "Parakeet companion", "version": "1.0.0", "api": "mac-companion-v1", "#
                    + #""features": {"speech": false, "youtubeAudio": false}, "#
                    + #""youtube": {"reason": "YouTube audio needs deno (brew install deno)."}}"#),
            "/v1/voices": .init(status: 200, body: #"{"voices": []}"#),
        ])
        let model = makeModel()
        model.host = "studio.local"
        model.newToken = token
        model.testConnection()
        await model.waitForTest()
        guard case .succeeded(_, let details) = model.testState else { return XCTFail("\(model.testState)") }
        XCTAssertTrue(details.contains("YouTube audio needs deno (brew install deno)."), "\(details)")
    }

    func testTestConnectionNamesAWrongToken() async {
        CompanionSettingsStubProtocol.reset([
            "/v1/companion": .init(
                status: 200,
                body: #"{"name": "Parakeet companion", "version": "1.0.0", "api": "mac-companion-v1", "#
                    + #""features": {"speech": false, "youtubeAudio": true}}"#),
            "/v1/voices": .init(status: 401, body: #"{"error": {"code": "unauthorized", "message": "no"}}"#),
        ])
        let model = makeModel()
        model.host = "studio.local"
        model.newToken = "wrong"
        model.testConnection()
        await model.waitForTest()
        XCTAssertEqual(model.testState, .failed(CompanionError.unauthorized.errorDescription!))
    }

    func testTestConnectionWithABadAddressFailsAtOnce() {
        let model = makeModel()
        model.host = ""
        model.testConnection()
        XCTAssertEqual(model.testState, .failed(CompanionAddress.ParseError.missingHost.errorDescription!))
    }
}
