import Foundation
import Synchronization
import XCTest

/// A canned HTTP answer for `IngestStubURLProtocol`. No real network is ever used in these tests.
struct IngestStubResponse: Sendable {
    var status: Int = 200
    var headers: [String: String] = [:]
    /// Delivered as separate `didLoad` calls, like network chunks.
    var chunks: [Data] = []
    /// When true, the stub sends the headers and the first chunk, then never finishes (until the task is cancelled).
    var hangsAfterFirstChunk = false
    /// When set, the body is `count` copies of `chunk`, sent one at a time from the stub's own queue. After each one
    /// the stub waits (up to 50 ms) for the client to stop the load, and stops sending once it has, like a server
    /// whose connection was closed. `IngestStubURLProtocol.deliveredBytes` counts what was sent.
    var streamed: (chunk: Data, count: Int)?

    static func body(_ data: Data, status: Int = 200, contentType: String?, extraHeaders: [String: String] = [:])
        -> IngestStubResponse
    {
        var headers = extraHeaders
        if let contentType { headers["Content-Type"] = contentType }
        headers["Content-Length"] = "\(data.count)"
        return IngestStubResponse(status: status, headers: headers, chunks: [data])
    }

    static func text(_ text: String, status: Int = 200, contentType: String = "text/plain") -> IngestStubResponse {
        body(Data(text.utf8), status: status, contentType: contentType)
    }
}

/// One request the stub saw.
struct IngestRecordedRequest: Sendable {
    var url: URL
    var method: String
    var headers: [String: String]
    var body: Data

    func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    var json: [String: Any]? {
        (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
    }
}

/// Intercepts every request of a session built from `configuration()`. One handler at a time (these tests run
/// serially); every request is recorded.
final class IngestStubURLProtocol: URLProtocol, @unchecked Sendable {
    private struct State {
        var handler: (@Sendable (IngestRecordedRequest) -> IngestStubResponse)?
        var requests: [IngestRecordedRequest] = []
        var deliveredBytes = 0
    }

    private static let state = Mutex(State())
    private static let streamQueue = DispatchQueue(label: "IngestStubURLProtocol.stream")
    /// Signalled by `stopLoading` (the client cancelled or finished the task).
    private let stopped = DispatchSemaphore(value: 0)
    private let isStopped = Mutex(false)

    /// Body bytes the stub has sent since the last `reset`.
    static var deliveredBytes: Int {
        state.withLock { $0.deliveredBytes }
    }

    static func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [IngestStubURLProtocol.self]
        configuration.urlCache = nil
        return configuration
    }

    static func reset(_ handler: @escaping @Sendable (IngestRecordedRequest) -> IngestStubResponse) {
        state.withLock {
            $0.handler = handler
            $0.requests = []
            $0.deliveredBytes = 0
        }
    }

    static var requests: [IngestRecordedRequest] {
        state.withLock { $0.requests }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let recorded = IngestRecordedRequest(
            url: request.url!,
            method: request.httpMethod ?? "GET",
            headers: request.allHTTPHeaderFields ?? [:],
            body: Self.readBody(request)
        )
        let handler = Self.state.withLock { state -> (@Sendable (IngestRecordedRequest) -> IngestStubResponse)? in
            state.requests.append(recorded)
            return state.handler
        }
        let response = handler?(recorded) ?? IngestStubResponse(status: 500, chunks: [Data("no stub".utf8)])
        let http = HTTPURLResponse(
            url: request.url!, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: response.headers)!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        if response.hangsAfterFirstChunk {
            if let first = response.chunks.first {
                client?.urlProtocol(self, didLoad: first)
            }
            return
        }
        if let streamed = response.streamed {
            Self.streamQueue.async { [self] in stream(streamed.chunk, count: streamed.count) }
            return
        }
        for chunk in response.chunks {
            client?.urlProtocol(self, didLoad: chunk)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    private func stream(_ chunk: Data, count: Int) {
        for _ in 0..<count {
            if isStopped.withLock({ $0 }) { return }
            client?.urlProtocol(self, didLoad: chunk)
            Self.state.withLock { $0.deliveredBytes += chunk.count }
            if stopped.wait(timeout: .now() + .milliseconds(50)) == .success { return }
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {
        isStopped.withLock { $0 = true }
        stopped.signal()
    }

    private static func readBody(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

/// A fresh temporary folder per test, removed afterwards.
func makeTemporaryDirectory(file: StaticString = #filePath, line: UInt = #line) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("ChirpIngestTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
