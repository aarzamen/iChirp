import ChirpCore
import Foundation

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
public struct IngestHTTPClient: Sendable {
    /// The largest body a metadata request reads (a podcast feed can be a few MB; captions are small).
    public static let defaultMaximumBytes = 16 * 1_024 * 1_024
    /// Sent with every request so servers can tell Parakeet apart; carries no device or user detail.
    public static let userAgent = "Parakeet/1.0 (iPhone; transcription app)"

    let session: URLSession

    public init(configuration: URLSessionConfiguration = IngestHTTPClient.privateConfiguration()) {
        session = URLSession(configuration: configuration)
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

    /// Sends `request` and returns the body of a 2xx answer. Other statuses throw `IngestNetworkError.httpStatus`.
    public func send(_ request: URLRequest, maximumBytes: Int = defaultMaximumBytes) async throws -> (
        Data, HTTPURLResponse
    ) {
        var request = request
        if request.value(forHTTPHeaderField: "User-Agent") == nil {
            request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        }
        let result: (Data, URLResponse)
        do {
            result = try await session.data(for: request)
        } catch {
            throw IngestNetworkError.map(error)
        }
        guard let http = result.1 as? HTTPURLResponse else { throw IngestNetworkError.notHTTP }
        guard (200...299).contains(http.statusCode) else { throw IngestNetworkError.httpStatus(http.statusCode) }
        guard result.0.count <= maximumBytes else { throw IngestNetworkError.tooLarge }
        return (result.0, http)
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
    /// its first byte. Returns the final URL after redirects and the content type.
    public func probe(_ url: URL) async throws -> LinkProbeResult {
        var head = URLRequest(url: url)
        head.httpMethod = "HEAD"
        head.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        do {
            let (_, response) = try await send(head, maximumBytes: 0)
            return LinkProbeResult(response: response, requested: url)
        } catch let error as IngestNetworkError {
            guard case .httpStatus = error else { throw error }
        }
        var ranged = URLRequest(url: url)
        ranged.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        let (_, response) = try await send(ranged, maximumBytes: 64 * 1_024)
        return LinkProbeResult(response: response, requested: url)
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
