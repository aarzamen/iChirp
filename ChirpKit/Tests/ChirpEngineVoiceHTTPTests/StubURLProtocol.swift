import Foundation
import Synchronization

// Copied from ChirpEngineHTTPLLMTests/StubURLProtocol.swift (test targets cannot share sources); default content type
// is audio.

/// A canned HTTP response for `StubURLProtocol`.
struct StubResponse: Sendable {
    var status: Int = 200
    var headers: [String: String] = ["Content-Type": "audio/mpeg"]
    /// Delivered as separate `didLoad` calls, like network chunks.
    var chunks: [Data] = []
    /// When set, the stub answers with a redirect to this URL instead of a body.
    var redirectTo: URL?

    static func body(_ text: String, status: Int = 200, contentType: String = "application/json") -> StubResponse {
        StubResponse(status: status, headers: ["Content-Type": contentType], chunks: [Data(text.utf8)])
    }

    static func audio(_ data: Data, contentType: String = "audio/mpeg") -> StubResponse {
        StubResponse(headers: ["Content-Type": contentType], chunks: [data])
    }
}

/// One request the stub saw, with its body read from the body stream.
struct RecordedRequest: Sendable {
    var url: URL
    var method: String
    var headers: [String: String]
    var body: Data

    var json: [String: Any]? {
        (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
    }

    var bodyString: String { String(decoding: body, as: UTF8.self) }
}

/// Intercepts every request of a session configured with `StubURLProtocol.configuration()`. One handler at a time
/// (XCTest runs these tests serially); every request is recorded.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    private struct State {
        var handler: (@Sendable (RecordedRequest) -> StubResponse)?
        var requests: [RecordedRequest] = []
    }

    private static let state = Mutex(State())

    static func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        configuration.urlCache = nil
        return configuration
    }

    static func reset(_ handler: @escaping @Sendable (RecordedRequest) -> StubResponse) {
        state.withLock {
            $0.handler = handler
            $0.requests = []
        }
    }

    static var requests: [RecordedRequest] {
        state.withLock { $0.requests }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let recorded = RecordedRequest(
            url: request.url!,
            method: request.httpMethod ?? "GET",
            headers: request.allHTTPHeaderFields ?? [:],
            body: Self.readBody(request)
        )
        let handler = Self.state.withLock { state -> (@Sendable (RecordedRequest) -> StubResponse)? in
            state.requests.append(recorded)
            return state.handler
        }
        let response = handler?(recorded) ?? StubResponse(status: 500, chunks: [Data("no stub".utf8)])

        if let target = response.redirectTo {
            let redirect = HTTPURLResponse(
                url: recorded.url, statusCode: 307, httpVersion: "HTTP/1.1",
                headerFields: ["Location": target.absoluteString])!
            var newRequest = request
            newRequest.url = target
            client?.urlProtocol(self, wasRedirectedTo: newRequest, redirectResponse: redirect)
            client?.urlProtocol(self, didReceive: redirect, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        }

        let http = HTTPURLResponse(
            url: recorded.url, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: response.headers)!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        for chunk in response.chunks {
            client?.urlProtocol(self, didLoad: chunk)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func readBody(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
