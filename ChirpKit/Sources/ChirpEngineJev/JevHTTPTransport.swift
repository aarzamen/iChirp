// Ported from MacParakeet (GPL-3.0): Sources/MacParakeetCore/Services/LLM/LLMHTTPTransport.swift @ bbae9e0e
// Changes: a copy of iChirp's `ChirpEngineHTTPLLM/LLMHTTPTransport.swift` (itself this port), because an engine target
// depends only on ChirpCore (ADR-004): the same ephemeral, cache-free, cookie-free session and a task delegate that
// refuses every redirect, with one `data(for:)` that reads the body as it arrives and stops past a byte limit (review L4
// M5: a huge answer or error body never fills memory). Follow-up: lift one shared transport into ChirpCore instead of
// two copies. Also here: the key-artifact scrubber from `LLMHTTPErrorMapper.swift`, unchanged.

import ChirpCore
import Foundation

/// Sends Jev's requests. `Sendable`: `URLSession` is thread-safe.
struct JevHTTPTransport: Sendable {
    let session: URLSession

    /// The app-wide transport: one ephemeral session, created once.
    static let shared = JevHTTPTransport(configuration: Self.privateConfiguration())

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

    /// The whole body, or `invalidResponse` as soon as it (or its declared length) passes `limit` bytes; the rest is
    /// never read.
    func data(for request: URLRequest, limit: Int = JevWire.responseByteLimit) async throws -> (Data, HTTPURLResponse) {
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: request, delegate: JevRedirectRefuser.shared)
        } catch {
            throw Self.map(error)
        }
        let http = try Self.httpResponse(response)
        if http.expectedContentLength > Int64(limit) {
            bytes.task.cancel()
            throw LanguageModelError.invalidResponse
        }
        var data = Data()
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count > limit {
                    bytes.task.cancel()
                    throw LanguageModelError.invalidResponse
                }
            }
        } catch let error as LanguageModelError {
            throw error
        } catch {
            throw Self.map(error)
        }
        return (data, http)
    }

    /// A refused redirect completes the task with the 3xx response itself; surface it as `redirectRefused`.
    private static func httpResponse(_ response: URLResponse) throws -> HTTPURLResponse {
        guard let http = response as? HTTPURLResponse else {
            throw LanguageModelError.connectionFailed("The server did not answer over HTTP.")
        }
        if (300...399).contains(http.statusCode) {
            throw LanguageModelError.redirectRefused
        }
        return http
    }

    /// Keeps cancellation as `CancellationError`; everything else becomes `connectionFailed` (URL errors describe the
    /// connection, never the request body).
    static func map(_ error: Error) -> Error {
        if error is CancellationError { return error }
        if let urlError = error as? URLError, urlError.code == .cancelled { return CancellationError() }
        if error is LanguageModelError { return error }
        return LanguageModelError.connectionFailed(error.localizedDescription)
    }

    /// Strips obvious API-key artifacts from a provider message (`LLMHTTPErrorMapper.scrubAPIKeyArtifacts`, copied).
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

/// Refuses every HTTP redirect, so a request body is never forwarded past the configured host.
final class JevRedirectRefuser: NSObject, URLSessionTaskDelegate, Sendable {
    static let shared = JevRedirectRefuser()

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
