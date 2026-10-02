import Foundation

// Review R3-4: what the HTTP engine targets (ChirpEngineHTTPLLM, ChirpEngineJev, ChirpEngineVoiceHTTP) share instead of
// keeping copies that had drifted (one scrubber missed Gemini and Groq keys and the literal key, one transport showed
// up to 64 KB of raw error body, two read bodies of any size). Foundation only.

/// Makes a provider's error message safe to show: no API key, nothing key-shaped, and short.
///
/// Provider messages can echo the request (headers, query strings, the key itself). Conservative on purpose: a missed
/// pattern is acceptable, a false positive that hides the real error is not. Messages may still echo prompt text, so
/// they are shown to the user only, never logged or stored.
public enum ProviderMessageScrubber {
    /// The longest provider message an error carries to the screen; a longer one is cut and ends with "…".
    public static let maxMessageCharacters = 300

    /// Key shapes the engines meet, then header and query-string echoes.
    private static let patterns: [(pattern: String, replacement: String)] = [
        (#"\bsk-[A-Za-z0-9_\-]{8,}"#, "<api-key>"),  // OpenAI, Anthropic (sk-ant-), OpenRouter (sk-or-)
        (#"\bxai-[A-Za-z0-9_\-]{8,}"#, "<api-key>"),  // xAI
        (#"\bgsk_[A-Za-z0-9]{8,}"#, "<api-key>"),  // Groq
        (#"\bAIza[0-9A-Za-z_\-]{20,}"#, "<api-key>"),  // Google (Gemini)
        (#"\bBearer\s+[A-Za-z0-9._%\-+=/]{8,}"#, "Bearer <token>"),
        (#"(?i)\bx-api-key:\s*[A-Za-z0-9._%\-+=/]{8,}"#, "x-api-key: <token>"),
        (#"(?i)\bapi[_-]?key=[A-Za-z0-9._%\-+=/]{8,}"#, "api-key=<token>"),
        (#"(?i)\bkey=[A-Za-z0-9._%\-+=/]{16,}"#, "key=<token>"),
    ]

    /// `message` with `secret` itself (when it has 4 characters or more, so it cannot mask an ordinary word) and every
    /// key-shaped string replaced. Idempotent.
    public static func scrubbed(_ message: String, secret: SecretValue? = nil) -> String {
        var out = message
        if let secret {
            let raw = secret.reveal()
            if raw.count >= 4 { out = out.replacingOccurrences(of: raw, with: "<api-key>") }
        }
        for (pattern, replacement) in patterns {
            out = out.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        return out
    }

    /// Trimmed, and cut to `maxMessageCharacters` (with "…") when longer.
    public static func shortened(_ message: String) -> String {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxMessageCharacters else { return trimmed }
        return String(trimmed.prefix(maxMessageCharacters)) + "…"
    }

    /// What an error may carry to the screen: `scrubbed` first (a key is never half-cut), then `shortened`.
    public static func displayable(_ message: String, secret: SecretValue? = nil) -> String {
        shortened(scrubbed(message, secret: secret))
    }
}

/// Reads a response body as it arrives and refuses it past a byte limit, so a huge answer or error body never fills
/// memory (review R3-4; Jev review L4 M5). Each engine picks its limit and maps `TooLarge` onto its own error.
public enum BoundedResponseBody {
    /// The body passed `limit` bytes, or declared more; the rest was never read and the task was cancelled.
    public struct TooLarge: Error, Equatable {
        public let limit: Int

        public init(limit: Int) {
            self.limit = limit
        }
    }

    /// The whole body of `bytes`, or `TooLarge` as soon as it (or its declared `expectedLength`) passes `limit`.
    /// Transport errors and cancellation pass through unchanged.
    public static func collect(_ bytes: URLSession.AsyncBytes, expectedLength: Int64, limit: Int) async throws -> Data {
        if expectedLength > Int64(limit) {
            bytes.task.cancel()
            throw TooLarge(limit: limit)
        }
        var data = Data()
        if expectedLength > 0 { data.reserveCapacity(Int(expectedLength)) }
        for try await byte in bytes {
            data.append(byte)
            if data.count > limit {
                bytes.task.cancel()
                throw TooLarge(limit: limit)
            }
        }
        return data
    }
}
