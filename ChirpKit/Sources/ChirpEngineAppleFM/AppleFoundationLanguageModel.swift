// Fresh implementation (no upstream equivalent: MacParakeet runs MLX in-process). Wraps Apple's FoundationModels
// framework behind ChirpCore's `LanguageModel`. Decision: spec/adr/011-language-model-providers-direct-ports.md.

import ChirpCore
import Foundation
import FoundationModels

/// Apple's on-device model (Apple Intelligence). Runs on the iPhone, so every privacy class may use it.
///
/// - Availability is explicit: Apple Intelligence off, device not eligible, or model not ready each map to a
///   `LanguageModelUnavailableReason` the UI can show, and `generate` refuses to start while unavailable.
/// - The context window (about 4K tokens, shared by instructions, input and output) is read from the system at run
///   time (`SystemLanguageModel.contextSize`), so callers budget and map-reduce against the real value.
/// - Each call uses a fresh `LanguageModelSession`: requests are stateless, like every `LanguageModel`.
public struct AppleFoundationLanguageModel: LanguageModel {
    public static let engineID = LanguageModelProviderKind.appleFoundationModels.engineID

    public let descriptor = EngineDescriptor(
        id: AppleFoundationLanguageModel.engineID,
        kind: .language,
        provider: "Apple",
        displayName: "Apple on-device model",
        locality: .onDevice,
        license: "Apple system model (Apple Intelligence terms)"
    )

    private let model: SystemLanguageModel

    public init() {
        model = .default
    }

    public var endpointHost: String? { nil }

    public func contextWindowTokens() async -> Int? {
        model.contextSize
    }

    public func availability() async -> LanguageModelAvailability {
        Self.map(model.availability)
    }

    public func generate(_ request: GenerationRequest) -> AsyncThrowingStream<GenerationEvent, Error> {
        let model = self.model
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    if case .unavailable(let reason) = Self.map(model.availability) {
                        throw LanguageModelError.unavailable(reason)
                    }
                    let instructions = request.system.flatMap { $0.isEmpty ? nil : $0 }
                    let session = LanguageModelSession(model: model, instructions: instructions)
                    let options = GenerationOptions(maximumResponseTokens: request.maxOutputTokens)
                    let stream = session.streamResponse(to: request.prompt, options: options)

                    // Snapshots carry the whole text so far; forward only what is new.
                    var emitted = ""
                    for try await snapshot in stream {
                        try Task.checkCancellation()
                        let delta = Self.delta(from: emitted, to: snapshot.content)
                        if !delta.isEmpty {
                            continuation.yield(.text(delta))
                        }
                        emitted = snapshot.content
                    }
                    guard !emitted.isEmpty else {
                        throw LanguageModelError.streamingError("the on-device model returned no text")
                    }
                    continuation.yield(.usage(GenerationUsage(model: "apple-on-device")))
                    continuation.yield(.finished)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Self.map(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Mapping (internal for tests)

    static func map(_ availability: SystemLanguageModel.Availability) -> LanguageModelAvailability {
        switch availability {
        case .available:
            return .available
        case .unavailable(let reason):
            return .unavailable(map(reason))
        }
    }

    static func map(_ reason: SystemLanguageModel.Availability.UnavailableReason) -> LanguageModelUnavailableReason {
        switch reason {
        case .appleIntelligenceNotEnabled: .appleIntelligenceNotEnabled
        case .deviceNotEligible: .deviceNotEligible
        case .modelNotReady: .modelNotReady
        @unknown default: .other("Apple's on-device model reported an unknown state.")
        }
    }

    /// Maps framework errors onto `LanguageModelError`. Framework error descriptions are not forwarded: they can
    /// quote the prompt.
    static func map(_ error: Error) -> Error {
        if error is CancellationError || error is LanguageModelError { return error }
        guard let generationError = error as? LanguageModelSession.GenerationError else {
            return LanguageModelError.providerError(
                "the on-device model failed (\(String(describing: type(of: error))))")
        }
        switch generationError {
        case .exceededContextWindowSize:
            return LanguageModelError.contextTooLong
        case .assetsUnavailable:
            return LanguageModelError.unavailable(.modelNotReady)
        case .guardrailViolation:
            return LanguageModelError.refused("Apple's safety guardrails stopped this request.")
        case .refusal:
            return LanguageModelError.refused("the on-device model declined this request.")
        case .unsupportedLanguageOrLocale:
            return LanguageModelError.unsupportedLanguage
        case .rateLimited:
            return LanguageModelError.rateLimited
        case .concurrentRequests:
            return LanguageModelError.providerError("the on-device model is busy with another request.")
        case .decodingFailure, .unsupportedGuide:
            return LanguageModelError.invalidResponse
        @unknown default:
            return LanguageModelError.providerError("the on-device model failed.")
        }
    }

    /// The new text in `current` after `previous`. When the model revised earlier text (a snapshot that no longer
    /// starts with what was sent), the whole snapshot is not re-sent; only the suffix past the common prefix is.
    static func delta(from previous: String, to current: String) -> String {
        if current.hasPrefix(previous) {
            return String(current.dropFirst(previous.count))
        }
        let common = zip(previous, current).prefix { $0 == $1 }.count
        return String(current.dropFirst(max(common, previous.count)))
    }
}

/// Registration entry point (ADR-004).
public enum AppleFoundationModels {
    /// The system on-device model. Always constructible; check `availability()` before offering it.
    public static func makeDefault() -> AppleFoundationLanguageModel {
        AppleFoundationLanguageModel()
    }
}
