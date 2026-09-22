import Foundation

// M4 contract: spec/contracts/language-model-plugin-v1.md. Conformers: ChirpEngineAppleFM, ChirpEngineHTTPLLM.

/// One text-generation call. Stateless: engines keep no conversation between calls.
public struct GenerationRequest: Sendable, Equatable {
    public var system: String?
    public var prompt: String
    /// Routing input: the caller must only hand this request to an engine `PrivacyRoutingPolicy` allows.
    public var privacyClass: PrivacyClass
    public var maxOutputTokens: Int?

    public init(system: String? = nil, prompt: String, privacyClass: PrivacyClass, maxOutputTokens: Int? = nil) {
        self.system = system
        self.prompt = prompt
        self.privacyClass = privacyClass
        self.maxOutputTokens = maxOutputTokens
    }
}

/// Metadata about one finished call. Never content: token counts, the model the provider reported, why it stopped.
public struct GenerationUsage: Sendable, Equatable {
    public var promptTokens: Int?
    public var completionTokens: Int?
    /// The model id the provider reported, when it differs from or refines the configured one.
    public var model: String?
    /// Provider stop reason, e.g. "end_turn", "stop", "length".
    public var stopReason: String?

    public init(promptTokens: Int? = nil, completionTokens: Int? = nil, model: String? = nil, stopReason: String? = nil)
    {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.model = model
        self.stopReason = stopReason
    }
}

/// Streamed output of `LanguageModel.generate`.
///
/// Order: zero or more `.text` deltas, then at most one `.usage`, then `.finished` exactly once on success. A
/// stream that ends without `.finished` (or throws) did not complete; its text must not be treated as a document.
public enum GenerationEvent: Sendable, Equatable {
    /// The next piece of generated text (a delta, not the text so far).
    case text(String)
    /// Metadata for the run ledger; never content.
    case usage(GenerationUsage)
    case finished
}

/// Whether an engine can run right now, checked before any content is handed to it.
public enum LanguageModelAvailability: Sendable, Equatable {
    case available
    case unavailable(LanguageModelUnavailableReason)
}

/// Why an engine cannot run. Each case maps to one user-facing sentence (`message`).
public enum LanguageModelUnavailableReason: Sendable, Equatable {
    /// Apple Intelligence is turned off in Settings.
    case appleIntelligenceNotEnabled
    /// This device cannot run Apple's on-device model.
    case deviceNotEligible
    /// Apple's model is still downloading or preparing.
    case modelNotReady
    /// The provider is missing something the user must fill in (base URL, model, API key).
    case notConfigured(String)
    case other(String)

    public var message: String {
        switch self {
        case .appleIntelligenceNotEnabled:
            "Apple Intelligence is off. Turn it on in Settings → Apple Intelligence & Siri to use the on-device model."
        case .deviceNotEligible:
            "This iPhone cannot run Apple's on-device model. Choose a home-network or cloud model instead."
        case .modelNotReady:
            "Apple's on-device model is still downloading. Try again when it is ready."
        case .notConfigured(let detail):
            "This model is not set up yet: \(detail)"
        case .other(let detail):
            "This model is not available: \(detail)"
        }
    }
}

/// Errors every language engine maps its provider errors onto, so callers can react (for example, re-plan a
/// too-long input as map-reduce) without importing an SDK.
///
/// Associated strings are provider messages with API-key artifacts scrubbed. They can echo prompt text, so they may be
/// shown to the user on their own device but are **never logged or stored** (log and store `kindName` instead).
public enum LanguageModelError: Error, Sendable, Equatable, LocalizedError {
    case unavailable(LanguageModelUnavailableReason)
    /// The input did not fit the model's context window.
    case contextTooLong
    case authenticationFailed(String?)
    case rateLimited
    case modelNotFound(String)
    case connectionFailed(String)
    /// A redirect was refused: content is only ever sent to the configured host.
    case redirectRefused
    /// The model declined (guardrail or refusal).
    case refused(String)
    case unsupportedLanguage
    case providerError(String)
    /// The stream broke off or reported an error mid-response; the partial text is not a document.
    case streamingError(String)
    case invalidResponse

    /// A stable, content-free name for logs and the run ledger.
    public var kindName: String {
        switch self {
        case .unavailable: "unavailable"
        case .contextTooLong: "context_too_long"
        case .authenticationFailed: "authentication_failed"
        case .rateLimited: "rate_limited"
        case .modelNotFound: "model_not_found"
        case .connectionFailed: "connection_failed"
        case .redirectRefused: "redirect_refused"
        case .refused: "refused"
        case .unsupportedLanguage: "unsupported_language"
        case .providerError: "provider_error"
        case .streamingError: "streaming_error"
        case .invalidResponse: "invalid_response"
        }
    }

    public var errorDescription: String? {
        switch self {
        case .unavailable(let reason): reason.message
        case .contextTooLong: "The text is longer than this model can read at once."
        case .authenticationFailed(let detail):
            if let detail, !detail.isEmpty {
                "Authentication failed: \(detail)"
            } else {
                "Authentication failed. Check the API key."
            }
        case .rateLimited: "The provider is rate-limiting requests. Wait a moment and try again."
        case .modelNotFound(let detail): "Model not found: \(detail)"
        case .connectionFailed(let detail): "Could not reach the model: \(detail)"
        case .redirectRefused: "The server tried to redirect the request elsewhere, so nothing was sent."
        case .refused(let detail): "The model declined to answer: \(detail)"
        case .unsupportedLanguage: "This model does not support the transcript's language."
        case .providerError(let detail): "Provider error: \(detail)"
        case .streamingError(let detail): "The response was cut off: \(detail)"
        case .invalidResponse: "The model sent a response iChirp could not read."
        }
    }
}

/// A text-generation engine plug-in (on-device, LAN or cloud). Contract: `spec/contracts/language-model-plugin-v1.md`.
///
/// Engines do not enforce privacy; callers route every request through `PrivacyRoutingPolicy` first (ChirpFeatures'
/// `DeliverableService` is the only caller that hands transcript text to a `LanguageModel`).
public protocol LanguageModel: Sendable {
    var descriptor: EngineDescriptor { get }
    /// The lowercased host this engine sends content to, passed as `host:` to `PrivacyRoutingPolicy.allows`. nil for
    /// on-device engines. It must be the host of every request the engine makes (engines refuse redirects).
    var endpointHost: String? { get }
    /// The model's whole context window in tokens (instructions, input and output together), when known. Callers
    /// budget input against it and split long input (map-reduce) instead of truncating.
    func contextWindowTokens() async -> Int?
    /// Checked before any content is handed over. Never touches the network.
    func availability() async -> LanguageModelAvailability
    func generate(_ request: GenerationRequest) -> AsyncThrowingStream<GenerationEvent, Error>
}

extension LanguageModel {
    public var endpointHost: String? { nil }
    public func contextWindowTokens() async -> Int? { nil }
    public func availability() async -> LanguageModelAvailability { .available }
}
