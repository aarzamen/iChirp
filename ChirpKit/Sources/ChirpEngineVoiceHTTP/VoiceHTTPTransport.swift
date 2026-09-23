// Ported from Readback (owner's project): Sources/TTS/TTSProvider.swift (`TTSHTTP`) @ 696cef6
// Changes: an ephemeral, cache-free session with a delegate that refuses every redirect (Readback used
// `URLSession.shared`); status mapping onto ChirpCore's `SpeechSynthesisError`; provider messages are read from the
// usual JSON error shapes and scrubbed of the key before they reach an error (patterns as in ChirpEngineHTTPLLM's
// `LLMHTTPErrorMapper`, ported from MacParakeet). Cancellation stays `CancellationError`.

import ChirpCore
import Foundation

/// Sends the voice engines' requests. `Sendable`: `URLSession` is thread-safe.
struct VoiceHTTPTransport: Sendable {
    let session: URLSession

    /// The app-wide transport: one ephemeral session, created once.
    static let shared = VoiceHTTPTransport(configuration: privateConfiguration())

    init(configuration: URLSessionConfiguration) {
        session = URLSession(configuration: configuration)
    }

    /// Ephemeral (nothing written to disk), no URL cache, no cookies. Tests add their `URLProtocol` stub to it.
    static func privateConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpCookieStorage = nil
        configuration.waitsForConnectivity = false
        return configuration
    }

    /// The body and response of any HTTP status except a redirect (refused: `redirectRefused`). Connection failures
    /// become `connectionFailed`; cancellation stays `CancellationError`.
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let result: (Data, URLResponse)
        do {
            result = try await session.data(for: request, delegate: VoiceRedirectRefuser.shared)
        } catch {
            throw Self.map(error)
        }
        guard let http = result.1 as? HTTPURLResponse else {
            throw SpeechSynthesisError.connectionFailed("The server did not answer over HTTP.")
        }
        // A refused redirect completes the task with the 3xx response itself.
        if (300...399).contains(http.statusCode) { throw SpeechSynthesisError.redirectRefused }
        return (result.0, http)
    }

    static func map(_ error: Error) -> Error {
        if error is CancellationError { return error }
        if let urlError = error as? URLError, urlError.code == .cancelled { return CancellationError() }
        if error is SpeechSynthesisError { return error }
        return SpeechSynthesisError.connectionFailed(error.localizedDescription)
    }
}

/// Refuses every HTTP redirect, so text is never forwarded past the configured host (a trusted Mac could otherwise
/// bounce a clinical request body to the internet).
final class VoiceRedirectRefuser: NSObject, URLSessionTaskDelegate, Sendable {
    static let shared = VoiceRedirectRefuser()

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

/// HTTP status → `SpeechSynthesisError`, with the provider's message read and scrubbed.
enum VoiceHTTPErrors {
    /// The generic mapping (Readback's `TTSHTTP.send`): 401/403 unauthorized, 429 rate limited, anything else a
    /// server error carrying the provider's (scrubbed, shortened) message.
    static func map(status: Int, data: Data, secret: SecretValue?) -> SpeechSynthesisError {
        switch status {
        case 401, 403: return .unauthorized
        case 429: return .rateLimited
        default: return .server(status: status, message: message(from: data, secret: secret))
        }
    }

    /// The provider's error sentence: `{"error": {"message": …}}`, `{"error": "…"}`, FastAPI's `{"detail": "…"}`, or
    /// the body's first 300 characters. Always scrubbed of `secret` and key-like strings.
    static func message(from data: Data, secret: SecretValue?) -> String {
        scrub(rawMessage(from: data), secret: secret)
    }

    /// `{"error": {"code": …}}` when the provider sends one (the companion does).
    static func code(from data: Data) -> String? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let error = object["error"] as? [String: Any]
        else { return nil }
        return error["code"] as? String
    }

    private static func rawMessage(from data: Data) -> String {
        if let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            if let error = object["error"] as? [String: Any], let message = error["message"] as? String {
                return message
            }
            if let error = object["error"] as? String { return error }
            if let detail = object["detail"] as? String { return detail }
            if let message = object["message"] as? String { return message }
        }
        let text = String(decoding: data.prefix(300), as: UTF8.self)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Removes the key itself and anything key-shaped (xAI `xai-…`, `sk-…`, `Bearer …`, `key=…`). Conservative: a
    /// missed pattern is acceptable, masking the real error is not.
    static func scrub(_ message: String, secret: SecretValue?) -> String {
        var out = message
        if let secret, !secret.isEmpty {
            out = out.replacingOccurrences(of: secret.reveal(), with: "<api-key>")
        }
        let patterns: [(String, String)] = [
            (#"\bxai-[A-Za-z0-9_\-]{8,}"#, "<api-key>"),
            (#"\bsk-[A-Za-z0-9_\-]{8,}"#, "<api-key>"),
            (#"\bBearer\s+[A-Za-z0-9._%\-+=/]{8,}"#, "Bearer <token>"),
            (#"(?i)\bapi[_-]?key=[A-Za-z0-9._%\-+=/]{8,}"#, "api-key=<token>"),
            (#"(?i)\bkey=[A-Za-z0-9._%\-+=/]{16,}"#, "key=<token>"),
        ]
        for (pattern, replacement) in patterns {
            out = out.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        return out
    }
}
