import ChirpCore
import ChirpIngest
import Foundation
import Observation

/// Settings → Mac companion: the form (host, port, pairing token, trusted), Save, Test connection and Remove.
///
/// The token field is write-only: a saved token is never read back into it; leaving the field empty keeps the saved
/// one. Test connection uses what is on screen (saved or not): the health check without the token, then the voices
/// list with it, which proves the pairing.
@MainActor @Observable public final class CompanionSettingsViewModel {
    public enum TestState: Equatable, Sendable {
        case idle
        case testing
        /// Connected and paired; the lines describe what the Mac offers.
        case succeeded(summary: String, details: [String])
        case failed(String)
    }

    public var host: String = "" {
        didSet { if host != oldValue { edited() } }
    }
    public var port: String = "" {
        didSet { if port != oldValue { edited() } }
    }
    /// A new pairing token; empty keeps the saved one.
    public var newToken: String = "" {
        didSet { if newToken != oldValue { edited() } }
    }
    public var isTrusted: Bool = false {
        didSet { if isTrusted != oldValue { edited() } }
    }

    public private(set) var isConfigured = false
    public private(set) var hasSavedToken = false
    public private(set) var hasUnsavedChanges = false
    public private(set) var testState: TestState = .idle
    public private(set) var errorMessage: String?

    @ObservationIgnored private let store: CompanionSettingsStore
    @ObservationIgnored private let makeClient: @Sendable (CompanionEndpoint, SecretValue?) -> CompanionClient
    @ObservationIgnored private var loading = false
    @ObservationIgnored private var testTask: Task<Void, Never>?

    /// - Parameter makeClient: builds the client Test connection uses (tests inject a stubbed session).
    public init(
        store: CompanionSettingsStore,
        makeClient: @escaping @Sendable (CompanionEndpoint, SecretValue?) -> CompanionClient = {
            CompanionClient(endpoint: $0, token: $1)
        }
    ) {
        self.store = store
        self.makeClient = makeClient
        load()
    }

    isolated deinit {
        testTask?.cancel()
    }

    /// Re-reads the saved companion into the form.
    public func load() {
        loading = true
        defer { loading = false }
        let endpoint = store.companionEndpoint()
        host = endpoint?.host ?? ""
        port = endpoint.map { String($0.port) } ?? String(CompanionEndpoint.defaultPort)
        isTrusted = endpoint?.isTrustedForClinicalText ?? false
        newToken = ""
        isConfigured = endpoint != nil
        hasSavedToken = ((try? store.companionPairingToken()) ?? nil).map { !$0.isEmpty } ?? false
        hasUnsavedChanges = false
        errorMessage = nil
    }

    /// The endpoint the form describes, or nil with `errorMessage` set.
    public var formEndpoint: CompanionEndpoint? {
        try? CompanionAddress.parse(host: host, port: port, trusted: isTrusted)
    }

    /// The host is on the internet, so it can never be trusted with clinical text (the toggle is off and disabled).
    public var isInternetAddress: Bool {
        guard let endpoint = formEndpoint else { return false }
        return endpoint.locality != .localNetwork
    }

    /// Saves the form. Returns false (with `errorMessage`) when the form is not valid or the Keychain refused.
    @discardableResult
    public func save() -> Bool {
        do {
            let endpoint = try CompanionAddress.parse(host: host, port: port, trusted: isTrusted && !isInternetAddress)
            let token = newToken.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty || hasSavedToken else {
                errorMessage = "Enter the pairing token the companion printed on your Mac."
                return false
            }
            try store.save(endpoint, token: token.isEmpty ? .keep : .set(SecretValue(token)))
            load()
            return true
        } catch {
            errorMessage = LinkIngestService.readable(error)
            return false
        }
    }

    /// Closes the error alert; the form keeps what the person typed.
    public func dismissError() {
        errorMessage = nil
    }

    /// Forgets the companion and its token (the person confirmed in the screen).
    public func remove() {
        do {
            try store.remove()
            load()
            testState = .idle
        } catch {
            errorMessage = LinkIngestService.readable(error)
        }
    }

    /// Checks the Mac on screen: health (no token), then the voices list (with the token), and reports both.
    public func testConnection() {
        testTask?.cancel()
        let endpoint: CompanionEndpoint
        do {
            endpoint = try CompanionAddress.parse(host: host, port: port, trusted: isTrusted)
        } catch {
            testState = .failed(LinkIngestService.readable(error))
            return
        }
        let typed = newToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = typed.isEmpty ? ((try? store.companionPairingToken()) ?? nil) : SecretValue(typed)
        let client = makeClient(endpoint, token)
        testState = .testing
        testTask = Task { [weak self] in
            let state = await Self.test(client, hasToken: token.map { !$0.isEmpty } ?? false)
            guard !Task.isCancelled else { return }
            self?.testState = state
        }
    }

    /// Waits for a running test (tests).
    public func waitForTest() async {
        await testTask?.value
    }

    nonisolated static func test(_ client: CompanionClient, hasToken: Bool) async -> TestState {
        let health: CompanionHealth
        do {
            health = try await client.health()
        } catch {
            return .failed(LinkIngestService.readable(error))
        }
        var details = [
            health.features.speech
                ? "Voices: " + (health.speech?.models.joined(separator: ", ") ?? "ready")
                : "Voices: none ready on the Mac yet",
            health.features.youtubeAudio ? "YouTube audio: ready" : "YouTube audio: not installed on the Mac",
        ]
        guard hasToken else {
            return .failed("Reached \(health.name) \(health.version), but there is no pairing token. Enter it above.")
        }
        do {
            let voices = try await client.voices()
            details.insert("\(voices.count) voice\(voices.count == 1 ? "" : "s") available", at: 1)
        } catch CompanionError.unauthorized {
            return .failed(CompanionError.unauthorized.errorDescription ?? "")
        } catch CompanionError.server(let status, _, _) where status == 503 {
            // Paired, but speech is not installed on the Mac: the token was accepted.
        } catch {
            return .failed(LinkIngestService.readable(error))
        }
        return .succeeded(summary: "Connected to \(health.name) \(health.version)", details: details)
    }

    private func edited() {
        guard !loading else { return }
        hasUnsavedChanges = true
        errorMessage = nil
        if testState != .testing { testState = .idle }
    }
}
