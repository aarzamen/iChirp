// M4 contract; no conformers in M1.

/// One text-generation call.
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

/// Streamed output of `LanguageModel.generate`.
public enum GenerationEvent: Sendable, Equatable {
    case text(String)
    case finished
}

/// A text-generation engine plug-in (on-device, LAN or cloud).
public protocol LanguageModel: Sendable {
    var descriptor: EngineDescriptor { get }
    func generate(_ request: GenerationRequest) -> AsyncThrowingStream<GenerationEvent, Error>
}
