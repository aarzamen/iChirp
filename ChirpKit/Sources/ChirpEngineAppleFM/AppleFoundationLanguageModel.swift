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
                    let stream = session.streamResponse(to: request.prompt, options: Self.options(for: request))

                    // Snapshots carry the whole text so far; forward only what is new.
                    var emitted = ""
                    for try await snapshot in stream {
                        try Task.checkCancellation()
                        guard let delta = Self.delta(from: emitted, to: snapshot.content) else {
                            throw LanguageModelError.streamingError(
                                "the on-device model rewrote text it had already sent")
                        }
                        if !delta.isEmpty {
                            continuation.yield(.text(delta))
                        }
                        emitted = snapshot.content
                    }
                    guard !emitted.isEmpty else {
                        throw LanguageModelError.streamingError("the on-device model returned no text")
                    }
                    continuation.yield(.usage(Self.finishedUsage))
                    continuation.yield(.finished)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Self.map(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Options (internal for tests)

    /// The options for one request.
    ///
    /// - A clinical request samples greedily (review R3-2, ADR-015's faithful sampling: always the most likely token,
    ///   so a random draw never changes a dose or a vital, and Retry gives the same draft). Apple's model has no
    ///   penalty setting. Other requests keep Apple's default sampling.
    /// - `maximumResponseTokens` is never set (review R3-1): FoundationModels ends a response at that cap early with
    ///   no error and no signal (Apple's documentation), so a cut-off answer would pass as finished. Uncapped, the
    ///   answer is bounded by the context window, and one that outgrows it throws `exceededContextWindowSize`
    ///   (`contextTooLong`: the planner re-plans with smaller parts). So here `request.maxOutputTokens` is the
    ///   planner's estimate, not a cap.
    static func options(for request: GenerationRequest) -> GenerationOptions {
        GenerationOptions(sampling: request.requiresFaithfulSampling ? .greedy : nil)
    }

    /// What a finished stream reports. Apple gives no stop word; uncapped, a response that finishes ended on its own.
    static let finishedUsage = GenerationUsage(model: "apple-on-device", stopReason: "stop")

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

    /// The new text in `current` after `previous`, compared Unicode scalar by Unicode scalar (review R3-10), so the
    /// deltas always add up to exactly the model's text: a snapshot that merges the last character (an emoji skin-tone
    /// modifier, a combining accent, a flag's second half) still extends what was sent. Nil when the snapshot rewrote
    /// text already sent: no delta can express that, and the stream fails instead of storing a hybrid.
    static func delta(from previous: String, to current: String) -> String? {
        let sent = previous.unicodeScalars
        let now = current.unicodeScalars
        guard now.starts(with: sent) else { return nil }
        return String(String.UnicodeScalarView(now.dropFirst(sent.count)))
    }
}

/// Registration entry point (ADR-004).
public enum AppleFoundationModels {
    /// The system on-device model. Always constructible; check `availability()` before offering it.
    public static func makeDefault() -> AppleFoundationLanguageModel {
        AppleFoundationLanguageModel()
    }
}
