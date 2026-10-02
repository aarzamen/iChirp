import ChirpCore
import Foundation
import Synchronization

/// Network failures of the link features, worded for the person.
public enum IngestNetworkError: Error, Equatable, LocalizedError {
    case offline
    case timedOut
    case httpStatus(Int)
    case notHTTP
    case tooLarge
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .offline:
            "You’re offline. Connect to the internet and try again."
        case .timedOut:
            "The server took too long to answer. Try again."
        case .httpStatus(let code):
            switch code {
            case 401, 403: "The server refused the request (HTTP \(code)). The link may be private or expired."
            case 404, 410: "Nothing was found at that link (HTTP \(code))."
            case 429: "The server is limiting requests (HTTP 429). Wait a minute and try again."
            default: "The server answered with an error (HTTP \(code))."
            }
        case .notHTTP:
            "The server did not answer over HTTP."
        case .tooLarge:
            "The server sent more data than expected."
        case .failed(let reason):
            "The request failed: \(reason)"
        }
    }

    /// Maps a URLSession error; cancellation stays `CancellationError`.
    static func map(_ error: any Error) -> any Error {
        if error is CancellationError || error is IngestNetworkError { return error }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cancelled: return CancellationError()
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff:
                return IngestNetworkError.offline
            case .timedOut: return IngestNetworkError.timedOut
            default: return IngestNetworkError.failed(urlError.localizedDescription)
            }
        }
        return IngestNetworkError.failed(error.localizedDescription)
    }
}

/// Small requests for the link features (podcast lookup, feeds, YouTube captions, the content-type probe).
///
/// Every request is started by a person's tap on Transcribe; nothing here runs on its own. Only the link and the ids
/// derived from it leave the phone, never user content (`spec/12-privacy.md`, network surfaces). The session is
/// ephemeral: no cookies are kept, nothing is cached to disk.
///
/// Bodies stream through a delegate: a body over its limit is refused as soon as the declared length or the bytes
/// received pass the limit, and the transfer is cancelled, so a large or hostile answer never sits in memory whole.
public struct IngestHTTPClient: Sendable {
    /// The largest body a metadata request reads (a podcast feed can be a few MB; captions are small).
    public static let defaultMaximumBytes = 16 * 1_024 * 1_024
    /// Sent with every request so servers can tell Parakeet apart; carries no device or user detail.
    public static let userAgent = "Parakeet/1.0 (iPhone; transcription app)"

    /// Each request gets its own session from this configuration (its delegate enforces the body limit).
    let configuration: URLSessionConfiguration

    public init(configuration: URLSessionConfiguration = IngestHTTPClient.privateConfiguration()) {
        self.configuration = configuration
    }

    /// What a request reads of the body.
    enum BodyLimit: Sendable {
        /// At most this many bytes; more is `IngestNetworkError.tooLarge`.
        case upTo(Int)
        /// None: the status and headers only (the probe). The transfer is cancelled once they arrive.
        case headersOnly
    }

    /// Ephemeral, no URL cache, no cookie storage. Tests add their `URLProtocol` stub to it.
    public static func privateConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpCookieStorage = nil
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 30
        return configuration
    }

    /// Sends `request` and returns the body of a 2xx answer. Other statuses throw `IngestNetworkError.httpStatus`; a
    /// body over `maximumBytes` throws `IngestNetworkError.tooLarge` while it streams.
    public func send(_ request: URLRequest, maximumBytes: Int = defaultMaximumBytes) async throws -> (
        Data, HTTPURLResponse
    ) {
        try await perform(request, body: .upTo(maximumBytes))
    }

    func perform(_ request: URLRequest, body: BodyLimit) async throws -> (Data, HTTPURLResponse) {
        var request = request
        if request.value(forHTTPHeaderField: "User-Agent") == nil {
            request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        }
        let collector = ResponseCollector(limit: body)
        let session = URLSession(configuration: configuration, delegate: collector, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = session.dataTask(with: request)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                collector.attach(continuation)
                if Task.isCancelled {
                    task.cancel()
                }
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    /// A GET of `url` with extra `headers`.
    public func get(_ url: URL, headers: [String: String] = [:], maximumBytes: Int = defaultMaximumBytes)
        async throws -> (Data, HTTPURLResponse)
    {
        var request = URLRequest(url: url)
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        return try await send(request, maximumBytes: maximumBytes)
    }

    /// Learns what a link serves without downloading it: a HEAD request, or (when the server refuses HEAD) a GET of
    /// its first byte whose transfer is cancelled as soon as the headers arrive, so a server that ignores `Range` and
    /// starts sending a whole video costs nothing. Returns the final URL after redirects and the content type.
    public func probe(_ url: URL) async throws -> LinkProbeResult {
        var head = URLRequest(url: url)
        head.httpMethod = "HEAD"
        head.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        do {
            let (_, response) = try await perform(head, body: .headersOnly)
            return LinkProbeResult(response: response, requested: url)
        } catch let error as IngestNetworkError {
            guard case .httpStatus = error else { throw error }
        }
        var ranged = URLRequest(url: url)
        ranged.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        let (_, response) = try await perform(ranged, body: .headersOnly)
        return LinkProbeResult(response: response, requested: url)
    }
}

/// One request's answer, collected under its body limit. All mutable state sits behind a `Mutex`; URLSession calls
/// these methods on its own serial delegate queue.
private final class ResponseCollector: NSObject, URLSessionDataDelegate, Sendable {
    private struct State {
        var continuation: CheckedContinuation<(Data, HTTPURLResponse), any Error>?
        var response: HTTPURLResponse?
        var body = Data()
        /// Decided before the transfer ended (a refused status, a body over the limit, headers-only done).
        var outcome: Result<(Data, HTTPURLResponse), any Error>?
    }

    private let limit: IngestHTTPClient.BodyLimit
    private let state = Mutex(State())

    init(limit: IngestHTTPClient.BodyLimit) {
        self.limit = limit
    }

    func attach(_ continuation: CheckedContinuation<(Data, HTTPURLResponse), any Error>) {
        state.withLock { $0.continuation = continuation }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        let disposition = state.withLock { state -> URLSession.ResponseDisposition in
            guard let http = response as? HTTPURLResponse else {
                state.outcome = .failure(IngestNetworkError.notHTTP)
                return .cancel
            }
            guard (200...299).contains(http.statusCode) else {
                state.outcome = .failure(IngestNetworkError.httpStatus(http.statusCode))
                return .cancel
            }
            switch limit {
            case .headersOnly:
                state.outcome = .success((Data(), http))
                return .cancel
            case .upTo(let maximumBytes):
                if http.expectedContentLength > Int64(maximumBytes) {
                    state.outcome = .failure(IngestNetworkError.tooLarge)
                    return .cancel
                }
                state.response = http
                return .allow
            }
        }
        completionHandler(disposition)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let overLimit = state.withLock { state -> Bool in
            guard state.outcome == nil, case .upTo(let maximumBytes) = limit else { return false }
            guard state.body.count + data.count <= maximumBytes else {
                state.outcome = .failure(IngestNetworkError.tooLarge)
                return true
            }
            state.body.append(data)
            return false
        }
        if overLimit {
            dataTask.cancel()
        }
    }

    private typealias Answer = Result<(Data, HTTPURLResponse), any Error>

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let (continuation, result) = state.withLock {
            state -> (CheckedContinuation<(Data, HTTPURLResponse), any Error>?, Answer) in
            let continuation = state.continuation
            state.continuation = nil
            if let outcome = state.outcome {
                return (continuation, outcome)
            }
            if let error {
                return (continuation, .failure(IngestNetworkError.map(error)))
            }
            guard let response = state.response else {
                return (continuation, .failure(IngestNetworkError.notHTTP))
            }
            return (continuation, .success((state.body, response)))
        }
        continuation?.resume(with: result)
    }
}

/// What a probed link serves.
public struct LinkProbeResult: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case media
        case feed
        case webPage
    }

    /// The link after redirects.
    public var finalURL: URL
    /// The content type, lowercased, without parameters (nil when the server sent none).
    public var mimeType: String?
    public var kind: Kind

    public init(finalURL: URL, mimeType: String?) {
        self.finalURL = finalURL
        self.mimeType = mimeType
        self.kind = Self.kind(mimeType: mimeType, url: finalURL)
    }

    init(response: HTTPURLResponse, requested: URL) {
        self.init(finalURL: response.url ?? requested, mimeType: response.mimeType?.lowercased())
    }

    /// Audio or video (or a generic binary with a media extension) is media; RSS or XML is a feed; anything else,
    /// HTML included, is a web page Parakeet cannot transcribe.
    static func kind(mimeType: String?, url: URL) -> Kind {
        let mime = mimeType ?? ""
        if mime.hasPrefix("audio/") || mime.hasPrefix("video/") {
            return .media
        }
        if mime.contains("rss") || mime.contains("atom") || mime == "application/xml" || mime == "text/xml" {
            return .feed
        }
        if mime.isEmpty || mime == "application/octet-stream" || mime == "binary/octet-stream" {
            return LinkClassifier.mediaExtensions.contains(url.pathExtension.lowercased()) ? .media : .webPage
        }
        return .webPage
    }
}
