// Semantics from MacParakeet (GPL-3.0): Sources/MacParakeetCore/Services/LLM/LLMClient.swift @ bbae9e0e — the
// adapter dispatch by provider kind. Fresh implementation of ChirpCore's `LanguageModel` over the ported adapters.

import ChirpCore
import Foundation

/// What an adapter needs from a provider configuration, with defaults resolved.
struct HTTPProviderSettings: Sendable {
    var kind: LanguageModelProviderKind
    var baseURL: URL
    var host: String?
    var modelName: String
    var apiKey: SecretValue?
    var locality: EngineLocality
    var contextWindowTokens: Int

    /// Local servers can take minutes to load a model on the first call (upstream cold-start timeouts).
    var streamTimeout: TimeInterval { locality == .cloud ? 120 : 600 }
    var requestTimeout: TimeInterval { locality == .cloud ? 30 : 300 }
}

/// One wire protocol (Anthropic Messages, OpenAI chat completions, Ollama `/api/chat`).
protocol LLMHTTPAdapter: Sendable {
    func stream(
        _ request: GenerationRequest,
        settings: HTTPProviderSettings,
        transport: LLMHTTPTransport
    ) -> AsyncThrowingStream<GenerationEvent, Error>

    /// A minimal non-streaming call ("Hi", one token): proves address, key and model. Sends no user content.
    func testConnection(settings: HTTPProviderSettings, transport: LLMHTTPTransport) async throws

    func listModels(settings: HTTPProviderSettings, transport: LLMHTTPTransport) async throws -> [String]
}

/// A language model reached over HTTP: Anthropic, an OpenAI-compatible server, or Ollama, in the cloud or on the LAN.
///
/// Holds the API key only in memory as a redacted `SecretValue`; printing or dumping the model never shows it.
/// Every request goes to `configuration.baseURL`'s host (`endpointHost`) and redirects are refused.
public struct HTTPLanguageModel: LanguageModel {
    public let configuration: LanguageModelProviderConfiguration
    public let descriptor: EngineDescriptor
    private let settings: HTTPProviderSettings?
    private let adapter: any LLMHTTPAdapter
    private let transport: LLMHTTPTransport

    init(
        configuration: LanguageModelProviderConfiguration,
        apiKey: SecretValue?,
        transport: LLMHTTPTransport
    ) {
        self.configuration = configuration
        self.transport = transport
        descriptor = HTTPLanguageModels.descriptor(for: configuration)
        adapter = HTTPLanguageModels.adapter(for: configuration.kind)
        let key = apiKey.flatMap { $0.isEmpty ? nil : $0 }
        settings = configuration.baseURL.map {
            HTTPProviderSettings(
                kind: configuration.kind,
                baseURL: $0,
                host: configuration.host,
                modelName: configuration.modelName.trimmingCharacters(in: .whitespacesAndNewlines),
                apiKey: key,
                locality: configuration.locality,
                contextWindowTokens: HTTPLanguageModels.contextWindowTokens(for: configuration)
            )
        }
    }

    public var endpointHost: String? { configuration.host }

    public func contextWindowTokens() async -> Int? {
        HTTPLanguageModels.contextWindowTokens(for: configuration)
    }

    public func availability() async -> LanguageModelAvailability {
        if let reason = unavailableReason() { return .unavailable(reason) }
        return .available
    }

    public func generate(_ request: GenerationRequest) -> AsyncThrowingStream<GenerationEvent, Error> {
        guard let settings, unavailableReason() == nil else {
            let reason = unavailableReason() ?? .notConfigured("the server address is missing")
            return AsyncThrowingStream { $0.finish(throwing: LanguageModelError.unavailable(reason)) }
        }
        return adapter.stream(request, settings: settings, transport: transport)
    }

    /// Settings → Models "Test connection": a one-token request with no user content.
    public func testConnection() async throws {
        guard let settings, unavailableReason() == nil else {
            throw LanguageModelError.unavailable(unavailableReason() ?? .notConfigured("the server address is missing"))
        }
        try await adapter.testConnection(settings: settings, transport: transport)
    }

    /// The provider's model ids, for the Settings model picker.
    public func listModels() async throws -> [String] {
        guard let settings else {
            throw LanguageModelError.unavailable(.notConfigured("the server address is missing"))
        }
        return try await adapter.listModels(settings: settings, transport: transport)
    }

    private func unavailableReason() -> LanguageModelUnavailableReason? {
        do {
            try configuration.validate()
        } catch {
            return .notConfigured(error.localizedDescription)
        }
        if configuration.requiresAPIKey, settings?.apiKey == nil {
            return .notConfigured("add the API key in Settings → Models")
        }
        return nil
    }
}

/// Registration entry point of the HTTP language engines (ADR-004): the app builds one `HTTPLanguageModel` per
/// configured provider, loading its key from the Keychain just before.
public enum HTTPLanguageModels {
    /// The provider kinds this target serves.
    public static let supportedKinds: [LanguageModelProviderKind] = [.anthropic, .openAICompatible, .ollama]

    public enum RegistrationError: Error, Equatable, LocalizedError {
        case unsupportedKind(LanguageModelProviderKind)

        public var errorDescription: String? {
            switch self {
            case .unsupportedKind(let kind): "\(kind.displayName) is not an HTTP provider."
            }
        }
    }

    /// Builds the engine for `configuration`. The configuration may still be incomplete; `availability()` then says
    /// what is missing and `generate` refuses to send.
    public static func make(
        configuration: LanguageModelProviderConfiguration,
        apiKey: SecretValue?
    ) throws -> HTTPLanguageModel {
        guard supportedKinds.contains(configuration.kind) else {
            throw RegistrationError.unsupportedKind(configuration.kind)
        }
        return HTTPLanguageModel(configuration: configuration, apiKey: apiKey, transport: .shared)
    }

    /// Test seam: the same engine over a caller-supplied session configuration (a `URLProtocol` stub).
    static func make(
        configuration: LanguageModelProviderConfiguration,
        apiKey: SecretValue?,
        sessionConfiguration: URLSessionConfiguration
    ) -> HTTPLanguageModel {
        HTTPLanguageModel(
            configuration: configuration, apiKey: apiKey,
            transport: LLMHTTPTransport(configuration: sessionConfiguration))
    }

    /// Default context windows (tokens) when the user did not set one. Ollama gets exactly this as `num_ctx`, so the
    /// planner's budget and the server's window agree and Ollama never truncates silently. LAN OpenAI-compatible
    /// servers (LM Studio) default to 4K because their loaded context is unknown; a larger window is a setting.
    public static func contextWindowTokens(for configuration: LanguageModelProviderConfiguration) -> Int {
        if let configured = configuration.contextWindowTokens, configured > 0 { return configured }
        switch configuration.kind {
        case .anthropic: return 200_000
        case .openAICompatible: return configuration.locality == .cloud ? 128_000 : 4_096
        case .ollama: return 8_192
        case .appleFoundationModels: return 4_096
        }
    }

    static func descriptor(for configuration: LanguageModelProviderConfiguration) -> EngineDescriptor {
        EngineDescriptor(
            id: configuration.kind.engineID,
            kind: .language,
            provider: configuration.kind.displayName,
            displayName: configuration.displayName,
            locality: configuration.locality,
            license: configuration.locality == .cloud
                ? "Proprietary (provider terms of service)"
                : "Per the model's own license (runs on your server)"
        )
    }

    static func adapter(for kind: LanguageModelProviderKind) -> any LLMHTTPAdapter {
        switch kind {
        case .anthropic: AnthropicLLMHTTPAdapter()
        case .ollama: OllamaLLMHTTPAdapter()
        case .openAICompatible, .appleFoundationModels: OpenAICompatibleLLMHTTPAdapter()
        }
    }
}
