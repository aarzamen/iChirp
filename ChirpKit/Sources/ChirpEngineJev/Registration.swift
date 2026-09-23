import ChirpCore
import Foundation

/// Registration entry point of the Jev decision engine (ADR-004). The app builds one `JevDecisionModel` right before a
/// decision or a connection test, with the key read from the Keychain just then.
public enum JevDecisionModels {
    /// Where the engine runs and what it is. Always `.cloud`, even against the DEBUG stub, so routing stays strict.
    public static let descriptor = EngineDescriptor(
        id: JevDecisionModel.engineID,
        kind: .structure,
        provider: "TypeSafe AI",
        displayName: "Jev",
        locality: .cloud,
        license: "Proprietary (TypeSafe API terms)"
    )

    static let missingKeyDetail = "add a Jev API key in Settings → Models"

    /// Builds the engine. The key may be missing; `availability()` then says so and `decide` sends nothing.
    public static func make(
        apiKey: SecretValue?,
        baseURL: URL = JevDecisionModel.defaultBaseURL,
        model: String = JevDecisionModel.defaultModel
    ) -> JevDecisionModel {
        JevDecisionModel(apiKey: apiKey, baseURL: baseURL, model: model, transport: .shared)
    }

    /// Test seam: the same engine over a caller-supplied session configuration (a `URLProtocol` stub).
    static func make(
        apiKey: SecretValue?,
        baseURL: URL,
        model: String,
        sessionConfiguration: URLSessionConfiguration
    ) -> JevDecisionModel {
        JevDecisionModel(
            apiKey: apiKey, baseURL: baseURL, model: model,
            transport: JevHTTPTransport(configuration: sessionConfiguration))
    }

    /// Why `url` cannot be Jev's address, or nil: http(s) with a host and no user or password, and https unless the
    /// host is on the local network (the DEBUG stub on this Mac).
    public static func problem(with url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
            let host = url.host(percentEncoded: false), !host.isEmpty
        else { return "the Jev address is not a web address" }
        guard url.user(percentEncoded: false) == nil, url.password(percentEncoded: false) == nil else {
            return "the Jev address must not contain a user name or password"
        }
        if scheme == "http", !LocalNetworkHost.isLocal(host) { return "the Jev address must use https" }
        return nil
    }

    /// The fixed, synthetic connection test: one question about one pangram. No user content, ever.
    public static let connectionTestRequest = DecisionRequest(
        state: DecisionState(text: "The quick brown fox jumps over the lazy dog."),
        questions: [
            DecisionQuestion(
                id: "connection_test",
                instructions: "What does the sentence mention first?",
                options: ["animal": "An animal", "vehicle": "A vehicle"])
        ],
        privacyClass: .general
    )
}

extension JevDecisionModel {
    /// Settings → Models "Test connection": proves address, key and model with the fixed synthetic sentence only.
    @discardableResult
    public func testConnection() async throws -> DecisionResult {
        try await decide(JevDecisionModels.connectionTestRequest)
    }
}
