// Ported from MacParakeet (GPL-3.0): Sources/MacParakeetCore/Services/LLM/LLMHTTPTransport.swift @ bbae9e0e
// Changes: transport only (error mapping and stream policy live in LLMHTTPErrorMapper.swift); every request uses an
// ephemeral, cache-free session and a task delegate that refuses **all** redirects (upstream refused only OpenCode Go
// redirects), so a POST body is only ever delivered to the configured host. Errors map to ChirpCore's
// `LanguageModelError`; cancellation stays `CancellationError`.

import ChirpCore
import Foundation

/// Sends requests for the HTTP language engines. `Sendable`: `URLSession` is thread-safe.
struct LLMHTTPTransport: Sendable {
    let session: URLSession

    /// The app-wide transport: one ephemeral session, created once.
    static let shared = LLMHTTPTransport(configuration: Self.privateConfiguration())

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

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let result: (Data, URLResponse)
        do {
            result = try await session.data(for: request, delegate: RedirectRefuser.shared)
        } catch {
            throw Self.map(error)
        }
        return (result.0, try Self.httpResponse(result.1))
    }

    func bytes(for request: URLRequest) async throws -> (URLSession.AsyncBytes, HTTPURLResponse) {
        let result: (URLSession.AsyncBytes, URLResponse)
        do {
            result = try await session.bytes(for: request, delegate: RedirectRefuser.shared)
        } catch {
            throw Self.map(error)
        }
        return (result.0, try Self.httpResponse(result.1))
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
}

/// Refuses every HTTP redirect, so content is never forwarded past the configured host (a trusted LAN host could
/// otherwise bounce a clinical request body to the internet).
final class RedirectRefuser: NSObject, URLSessionTaskDelegate, Sendable {
    static let shared = RedirectRefuser()

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

extension URLSession.AsyncBytes {
    /// Collects an error body (bounded, so a misbehaving server cannot exhaust memory).
    func collectErrorBody(limit: Int = 64 * 1024) async throws -> Data {
        var data = Data()
        for try await byte in self {
            data.append(byte)
            if data.count >= limit { break }
        }
        return data
    }
}
