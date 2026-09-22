// Ported from MacParakeet (GPL-3.0): Sources/MacParakeetCore/Services/LLM/LLMHTTPTransport.swift @ bbae9e0e
// Changes: `LLMHTTPErrorMapper`, `LLMHTTPStreamCompletionPolicy` and the shared error wire types, mapping onto ChirpCore's
// `LanguageModelError` instead of upstream `LLMError`; the sentinel policy is keyed by `HTTPProviderSettings` (kind
// and host) instead of upstream's provider-id enum. Also: 403 maps to authentication and 413 to context-too-long,
// Ollama's `{"error": "..."}` body is read for HTTP errors, and a top-level `message` counts as a stream error only
// next to an `error` key. Key scrubbing patterns and context-overflow wording are unchanged.

import ChirpCore
import Foundation

enum LLMHTTPErrorMapper {
    static func mapError(statusCode: Int, data: Data) -> LanguageModelError {
        // Providers use different formats:
        //   OpenAI/Anthropic: {"error": {"message": "..."}}
        //   Gemini:           [{"error": {"code": 404, "message": "...", "status": "NOT_FOUND"}}]
        //   Ollama:           {"error": "..."}
        let rawMessage: String
        if let errorBody = try? JSONDecoder().decode(OpenAIErrorResponse.self, from: data) {
            rawMessage = errorBody.error.message
        } else if let geminiArray = try? JSONDecoder().decode([OpenAIErrorResponse].self, from: data),
            let first = geminiArray.first
        {
            rawMessage = first.error.message
        } else if let streamError = try? JSONDecoder().decode(StreamErrorResponse.self, from: data),
            let message = streamError.error
        {
            rawMessage = message
        } else {
            rawMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
        }

        // Some providers echo the request shape in error responses; scrub key artifacts before the message reaches
        // Swift errors or the UI.
        let message = scrubAPIKeyArtifacts(from: rawMessage)

        switch statusCode {
        case 401, 403:
            return .authenticationFailed(message)
        case 429:
            return .rateLimited
        case 404:
            if message.lowercased().contains("model") {
                return .modelNotFound(message)
            }
            return .providerError(message)
        case 400, 413:
            if statusCode == 413 || isContextOverflowMessage(message) {
                return .contextTooLong
            }
            return .providerError(message)
        default:
            return .providerError(message)
        }
    }

    static func mapStreamingError(message rawMessage: String) -> LanguageModelError {
        let message = scrubAPIKeyArtifacts(from: rawMessage)
        let lowered = message.lowercased()

        if isContextOverflowMessage(message) {
            return .contextTooLong
        }
        if lowered.contains("rate limit") || lowered.contains("rate_limit") {
            return .rateLimited
        }
        if lowered.contains("unauthorized")
            || lowered.contains("authentication")
            || lowered.contains("api key")
        {
            return .authenticationFailed(message)
        }
        if lowered.contains("model")
            && (lowered.contains("not found") || lowered.contains("does not exist"))
        {
            return .modelNotFound(message)
        }
        return .streamingError(message)
    }

    /// True context-window failures, not parameter-compatibility errors that happen to mention `max_tokens`.
    static func isContextOverflowMessage(_ message: String) -> Bool {
        let lowered = message.lowercased()
        if isUnsupportedTokenParameterMessage(lowered) {
            return false
        }
        return lowered.contains("context length")
            || lowered.contains("context window")
            || lowered.contains("context limit")
            || lowered.contains("maximum context")
            || lowered.contains("too many tokens")
            || lowered.contains("tokens to keep")
            || lowered.contains("maximum number of tokens")
            || lowered.contains("prompt is too long")
    }

    private static func isUnsupportedTokenParameterMessage(_ lowered: String) -> Bool {
        let mentionsTokenParameter =
            lowered.contains("max_tokens") || lowered.contains("max_completion_tokens")
        let mentionsUnsupported =
            lowered.contains("unsupported")
            || lowered.contains("not supported")
            || lowered.contains("unknown parameter")
        return mentionsTokenParameter && mentionsUnsupported
    }

    /// Strips obvious API-key artifacts from a provider error message. Idempotent and conservative: false negatives
    /// are acceptable; false positives that mask the actual error are not.
    /// - `sk-...` and `sk-proj-...` / `sk-ant-...` style keys
    /// - `Bearer <token>`
    /// - `x-api-key: <token>` header echoes
    /// - `key=<token>` and `api[_-]?key=<token>` query-param echoes
    static func scrubAPIKeyArtifacts(from message: String) -> String {
        let patterns: [(String, String)] = [
            (#"\bsk-[A-Za-z0-9_\-]{8,}"#, "<api-key>"),
            (#"\bBearer\s+[A-Za-z0-9._%\-+=/]{8,}"#, "Bearer <token>"),
            (#"(?i)\bx-api-key:\s*[A-Za-z0-9._%\-+=/]{8,}"#, "x-api-key: <token>"),
            (#"(?i)\bapi[_-]?key=[A-Za-z0-9._%\-+=/]{8,}"#, "api-key=<token>"),
            (#"(?i)\bkey=[A-Za-z0-9._%\-+=/]{16,}"#, "key=<token>"),
        ]

        var out = message
        for (pattern, replacement) in patterns {
            out = out.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        return out
    }
}

enum LLMHTTPStreamCompletionPolicy {
    /// Strict providers contractually emit a stream terminator, so EOF without it means the connection dropped and
    /// the text is silently truncated: Anthropic (`message_stop`), OpenAI and OpenRouter (`[DONE]`). Lenient ones omit
    /// it often enough that enforcing it would give false failures: other OpenAI-compatible servers (LM Studio,
    /// llama.cpp, Gemini) and Ollama (whose `done: true` is detected separately).
    static func providerEnforcesStreamSentinel(_ settings: HTTPProviderSettings) -> Bool {
        switch settings.kind {
        case .anthropic:
            return true
        case .openAICompatible:
            return ["api.openai.com", "openrouter.ai"].contains(settings.host ?? "")
        case .ollama, .appleFoundationModels:
            return false
        }
    }

    static func validateStreamCompletion(
        settings: HTTPProviderSettings,
        sawSentinel: Bool,
        yieldedAnyContent: Bool
    ) throws {
        guard yieldedAnyContent else {
            throw LanguageModelError.streamingError("the stream produced no text before it ended")
        }
        guard providerEnforcesStreamSentinel(settings), !sawSentinel else { return }
        throw LanguageModelError.streamingError(
            "the stream ended before its completion marker; the response is incomplete")
    }
}

// MARK: - Shared wire types

struct OpenAIErrorResponse: Decodable {
    let error: ErrorDetail

    struct ErrorDetail: Decodable {
        let message: String
    }
}

/// Providers can emit error payloads mid-stream. Shapes observed in practice:
/// - Ollama: `{ "error": "..." }`
/// - LM Studio: `{ "error": { "message": "..." }, "message": "..." }`
struct StreamErrorResponse: Decodable {
    let error: String?

    private enum CodingKeys: String, CodingKey {
        case error
        case message
    }

    private struct ErrorObject: Decodable {
        let message: String?
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let message = try? container.decode(String.self, forKey: .message),
            !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            container.contains(.error)
        {
            error = message
            return
        }
        if let errorMessage = try? container.decode(String.self, forKey: .error),
            !errorMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            error = errorMessage
            return
        }
        if let errorObject = try? container.decode(ErrorObject.self, forKey: .error),
            let message = errorObject.message,
            !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            error = message
            return
        }
        error = nil
    }
}

struct ModelsListResponse: Decodable {
    let data: [ModelEntry]

    struct ModelEntry: Decodable {
        let id: String
        let type: String?
    }
}

/// Model ids that are clearly not text-generation models (embeddings, audio, images), hidden from model lists.
enum LLMHTTPModelCatalog {
    static func isClearlyNonTextModelID(_ model: String) -> Bool {
        let lowered = model.lowercased()
        let unsupportedSubstrings = [
            "audio", "clip", "computer-use", "dall-e", "diffusion", "embed", "image", "imagen", "moderation",
            "realtime", "rerank", "sora", "speech", "transcribe", "tts", "video", "whisper",
        ]
        return unsupportedSubstrings.contains(where: lowered.contains)
    }
}
