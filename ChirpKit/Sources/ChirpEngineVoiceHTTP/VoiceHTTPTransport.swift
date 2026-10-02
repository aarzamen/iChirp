// Ported from Readback (owner's project): Sources/TTS/TTSProvider.swift (`TTSHTTP`) @ 696cef6
// Changes: an ephemeral, cache-free session with a delegate that refuses every redirect (Readback used
// `URLSession.shared`); status mapping onto ChirpCore's `SpeechSynthesisError`; provider messages are read from the
// usual JSON error shapes, scrubbed of the key and cut at 300 characters before they reach an error, and bodies are read
// up to a size limit (ChirpCore's shared `ProviderMessageScrubber` and `BoundedResponseBody`, review R3-4).
// Cancellation stays `CancellationError`.

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

    /// The most one answer may be: about four times the longest speech either provider returns for its largest
    /// request (xAI mp3 of 15,000 characters, the companion's WAV of 4,000), far below what could fill memory.
    static let responseByteLimit = 64 * 1_024 * 1_024

    /// The body and response of any HTTP status except a redirect (refused: `redirectRefused`). The body is read as it
    /// arrives and refused past `limit` bytes (review R3-4, ChirpCore `BoundedResponseBody`). Connection failures
    /// become `connectionFailed`; cancellation stays `CancellationError`.
    func data(for request: URLRequest, limit: Int = Self.responseByteLimit) async throws -> (Data, HTTPURLResponse) {
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: request, delegate: VoiceRedirectRefuser.shared)
        } catch {
            throw Self.map(error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw SpeechSynthesisError.connectionFailed("The server did not answer over HTTP.")
        }
        // A refused redirect completes the task with the 3xx response itself.
        if (300...399).contains(http.statusCode) { throw SpeechSynthesisError.redirectRefused }
        do {
            let body = try await BoundedResponseBody.collect(
                bytes, expectedLength: http.expectedContentLength, limit: limit)
            return (body, http)
        } catch is BoundedResponseBody.TooLarge {
            throw SpeechSynthesisError.server(
                status: http.statusCode,
                message: "The answer was larger than \(limit / 1_048_576) MB, so it was not read.")
        } catch {
            throw Self.map(error)
        }
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
    /// the body's text. Always scrubbed of `secret` and key-like strings, then cut at 300 characters (ChirpCore's
    /// shared `ProviderMessageScrubber`, review R3-4).
    static func message(from data: Data, secret: SecretValue?) -> String {
        ProviderMessageScrubber.displayable(rawMessage(from: data), secret: secret)
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
        let text = String(decoding: data.prefix(2_048), as: UTF8.self)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
