import ChirpCore
import Foundation
import Synchronization

// Contract: spec/contracts/mac-companion-v1.md (server: companion/, plan 019). The phone side of the Parakeet
// companion for ingest: its health, its voices (plan 020 may reuse this list) and YouTube audio for videos without
// captions. Only the configured host is ever contacted: redirects are refused.

/// `GET /v1/companion`.
public struct CompanionHealth: Sendable, Equatable, Decodable {
    public struct Features: Sendable, Equatable, Decodable {
        public var speech: Bool
        public var youtubeAudio: Bool
    }

    public struct Speech: Sendable, Equatable, Decodable {
        public var models: [String]
        public var defaultModel: String?
    }

    public var name: String
    public var version: String
    public var api: String
    public var features: Features
    public var speech: Speech?

    public static let expectedAPI = "mac-companion-v1"
}

/// One voice of `GET /v1/voices`.
public struct CompanionVoiceInfo: Sendable, Equatable, Decodable, Identifiable {
    public var id: String
    public var name: String
    public var detail: String
    public var languages: [String]
    public var model: String
    public var supportsStyle: Bool
}

/// A video's audio, fetched by the companion and saved on this iPhone.
public struct CompanionAudio: Sendable, Equatable {
    /// `<directory>/<stem>.m4a`.
    public var fileURL: URL
    /// The video's title (`X-Companion-Title`), when YouTube gave one.
    public var title: String?
    public var durationMs: Int?
    public var byteCount: Int64

    public init(fileURL: URL, title: String?, durationMs: Int?, byteCount: Int64) {
        self.fileURL = fileURL
        self.title = title
        self.durationMs = durationMs
        self.byteCount = byteCount
    }
}

/// Companion failures, worded for the person.
public enum CompanionError: Error, Equatable, LocalizedError {
    /// No companion in Settings → Mac companion.
    case notConfigured
    /// A companion is set up but has no pairing token.
    case notPaired
    /// The host and port cannot form an address.
    case invalidAddress
    /// The address is not on the home network. The companion speaks plain http, so Parakeet never sends the token
    /// or a link to an internet address.
    case notHomeNetwork
    /// iOS refused plain http to this name (App Transport Security allows it for `.local` names and IP addresses).
    case insecureAddressBlocked(host: String)
    /// The Mac did not answer (not running, asleep, another network).
    case unreachable(host: String)
    case timedOut(host: String)
    /// The Mac refused the pairing token.
    case unauthorized
    /// Something answered that is not a Parakeet companion (or a different API version).
    case notACompanion
    /// The companion tried to send the phone elsewhere; Parakeet only talks to the configured host.
    case redirectRefused
    /// The companion answered with an error; `message` is its sentence for the person.
    case server(status: Int, code: String?, message: String?)
    case invalidResponse
    case emptyAudio
    /// A 2xx answer that is not audio (another web service on that address).
    case notAudio
    case writeFailed(String)

    /// The longest companion sentence shown (and stored on a failed row).
    public static let messageLimit = 300

    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            "Set up the Mac companion first: Settings → Mac companion."
        case .notPaired:
            "Enter the Mac companion’s pairing token in Settings → Mac companion."
        case .invalidAddress:
            "The Mac companion’s address is not valid. Check the host and port in Settings → Mac companion."
        case .notHomeNetwork:
            "The Mac companion must be on your home network: use your Mac’s name (like my-mac.local) or its home IP "
                + "address (like 192.168.1.20) in Settings → Mac companion."
        case .insecureAddressBlocked(let host):
            "iOS blocked plain http to \(host). Use your Mac’s name ending in .local (like my-mac.local) or its IP "
                + "address in Settings → Mac companion."
        case .unreachable(let host):
            "Parakeet couldn’t reach your Mac (\(host)). Check that the companion is running "
                + "(scripts/companion.sh), that this iPhone is on the same Wi-Fi, and that Parakeet may use the "
                + "Local Network (iOS Settings → Privacy & Security → Local Network)."
        case .timedOut(let host):
            "Your Mac (\(host)) took too long to answer. Try again."
        case .unauthorized:
            "Your Mac refused the pairing token. Copy it again from the Mac into Settings → Mac companion."
        case .notACompanion:
            "That address answered, but it is not a Parakeet companion. Check the host and port."
        case .redirectRefused:
            "Your Mac tried to send Parakeet to another address, so Parakeet stopped."
        case .server(let status, _, let message):
            message.flatMap { $0.isEmpty ? nil : Self.capped($0) }
                ?? "Your Mac answered with an error (HTTP \(status))."
        case .invalidResponse:
            "Your Mac sent an answer Parakeet could not read."
        case .emptyAudio:
            "Your Mac sent an empty audio file."
        case .notAudio:
            "That address answered with something that is not audio. Check the host and port in Settings → Mac "
                + "companion."
        case .writeFailed(let reason):
            "Couldn’t save the audio on this iPhone: \(reason)"
        }
    }

    static func capped(_ message: String) -> String {
        message.count <= messageLimit ? message : String(message.prefix(messageLimit - 1)) + "…"
    }
}

/// Fetches a YouTube video's audio through the companion (the seam `LinkIngestService` uses; tests fake it).
public protocol CompanionAudioFetching: Sendable {
    /// The companion this client talks to (a link confirmed for one Mac is not sent to another without asking).
    var endpoint: CompanionEndpoint { get }

    /// Sends `url` (the canonical watch link) to the companion, which downloads the audio from YouTube, and saves the
    /// answer as `<directory>/<fileStem>.m4a`. `progress` reports bytes as they arrive (total when the companion sent a
    /// length).
    func youtubeAudio(
        url: URL, into directory: URL, fileStem: String, progress: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws -> CompanionAudio
}

/// `mac-companion-v1` over plain http on the home network. Health goes without the token; everything else carries
/// `Authorization: Bearer <pairing token>`. Ephemeral session: no cookies, no cache. An address that is not on the
/// home network (`CompanionEndpoint.locality`) is refused before any request: plain http must not cross the internet.
public struct CompanionClient: CompanionAudioFetching {
    public static let healthPath = "/v1/companion"
    public static let voicesPath = "/v1/voices"
    public static let youtubePath = "/v1/youtube/audio"
    /// The companion stops a YouTube download after 15 minutes; the phone waits a little longer for its answer.
    public static let youtubeTimeout: TimeInterval = 16 * 60
    public static let shortTimeout: TimeInterval = 10

    public let endpoint: CompanionEndpoint
    private let token: SecretValue?
    private let makeConfiguration: @Sendable () -> URLSessionConfiguration
    private let logger = Log.logger("companion")

    /// - Parameter configuration: builds each request's session configuration (tests add a `URLProtocol` stub).
    public init(
        endpoint: CompanionEndpoint,
        token: SecretValue?,
        configuration: @escaping @Sendable () -> URLSessionConfiguration = { IngestHTTPClient.privateConfiguration() }
    ) {
        self.endpoint = endpoint
        self.token = token
        self.makeConfiguration = configuration
    }

    // MARK: - Health and voices

    /// `GET /v1/companion` (no token): name, version and what the companion can do now.
    public func health() async throws -> CompanionHealth {
        let (data, response) = try await send(try request(Self.healthPath, authorized: false))
        try Self.check(response, data)
        guard let health = try? JSONDecoder().decode(CompanionHealth.self, from: data),
            health.api == CompanionHealth.expectedAPI
        else {
            throw CompanionError.notACompanion
        }
        return health
    }

    /// `GET /v1/voices`: the voices of the models that are ready on the Mac. Also proves the token.
    public func voices() async throws -> [CompanionVoiceInfo] {
        let (data, response) = try await send(try request(Self.voicesPath, authorized: true))
        try Self.check(response, data)
        struct Voices: Decodable { var voices: [CompanionVoiceInfo] }
        guard let decoded = try? JSONDecoder().decode(Voices.self, from: data) else {
            throw CompanionError.invalidResponse
        }
        return decoded.voices
    }

    // MARK: - YouTube audio

    public func youtubeAudio(
        url: URL, into directory: URL, fileStem: String = "source",
        progress: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws -> CompanionAudio {
        var request = try request(Self.youtubePath, authorized: true)
        request.httpMethod = "POST"
        request.timeoutInterval = Self.youtubeTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("audio/mp4", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["url": url.absoluteString])
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw CompanionError.writeFailed(error.localizedDescription)
        }
        let partURL = directory.appendingPathComponent("companion.part", isDirectory: false)
        try? FileManager.default.removeItem(at: partURL)

        let delegate = CompanionDownloadDelegate(partURL: partURL, onProgress: progress)
        let configuration = makeConfiguration()
        configuration.timeoutIntervalForRequest = Self.youtubeTimeout
        configuration.timeoutIntervalForResource = Self.youtubeTimeout * 2
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = session.downloadTask(with: request)
        let outcome: CompanionDownloadDelegate.Outcome
        do {
            outcome = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    delegate.attach(continuation)
                    if Task.isCancelled { task.cancel() }
                    task.resume()
                }
            } onCancel: {
                task.cancel()
            }
        } catch {
            try? FileManager.default.removeItem(at: partURL)
            throw map(error)
        }
        try Self.check(outcome.response, outcome.errorBody ?? Data())
        guard outcome.byteCount > 0, FileManager.default.fileExists(atPath: partURL.path) else {
            try? FileManager.default.removeItem(at: partURL)
            throw CompanionError.emptyAudio
        }
        guard Self.isAudio(outcome.response.mimeType) else {
            try? FileManager.default.removeItem(at: partURL)
            throw CompanionError.notAudio
        }
        let fileExtension = MediaDownloader.fileExtension(
            for: URL(fileURLWithPath: "audio"), mimeType: outcome.response.mimeType ?? "audio/mp4")
        let destination = directory.appendingPathComponent("\(fileStem).\(fileExtension)", isDirectory: false)
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: partURL, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: partURL)
            throw CompanionError.writeFailed(error.localizedDescription)
        }
        let title = outcome.response.value(forHTTPHeaderField: "X-Companion-Title")?.removingPercentEncoding
            .flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        let durationMs = outcome.response.value(forHTTPHeaderField: "X-Companion-Duration-Ms").flatMap(Int.init)
        logger.info(
            "companion_youtube_audio bytes=\(outcome.byteCount, privacy: .public) ext=\(fileExtension, privacy: .public)"
        )
        return CompanionAudio(fileURL: destination, title: title, durationMs: durationMs, byteCount: outcome.byteCount)
    }

    // MARK: - Plumbing

    private func request(_ path: String, authorized: Bool) throws -> URLRequest {
        guard let base = endpoint.baseURL, let url = URL(string: path, relativeTo: base)?.absoluteURL else {
            throw CompanionError.invalidAddress
        }
        guard endpoint.locality == .localNetwork else { throw CompanionError.notHomeNetwork }
        var request = URLRequest(url: url)
        request.timeoutInterval = Self.shortTimeout
        request.setValue(IngestHTTPClient.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if authorized {
            guard let token, !token.isEmpty else { throw CompanionError.notPaired }
            request.setValue("Bearer \(token.reveal())", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let configuration = makeConfiguration()
        configuration.timeoutIntervalForRequest = Self.shortTimeout
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (data, response) = try await session.data(for: request, delegate: RedirectRefuser())
            guard let http = response as? HTTPURLResponse else { throw CompanionError.invalidResponse }
            return (data, http)
        } catch {
            throw map(error)
        }
    }

    /// 2xx passes; 3xx is a refused redirect; 401 is the token; anything else carries the companion's sentence.
    static func check(_ response: HTTPURLResponse, _ body: Data) throws {
        switch response.statusCode {
        case 200...299:
            return
        case 300...399:
            throw CompanionError.redirectRefused
        case 401:
            throw CompanionError.unauthorized
        default:
            struct Envelope: Decodable {
                struct Detail: Decodable {
                    var code: String?
                    var message: String?
                }
                var error: Detail
            }
            let detail = (try? JSONDecoder().decode(Envelope.self, from: body))?.error
            throw CompanionError.server(status: response.statusCode, code: detail?.code, message: detail?.message)
        }
    }

    /// The companion's audio (`audio/mp4` per the contract); anything else is refused.
    static func isAudio(_ mimeType: String?) -> Bool {
        guard let type = mimeType?.lowercased() else { return false }
        return type.hasPrefix("audio/") || type == "video/mp4"
    }

    private func map(_ error: any Error) -> any Error {
        Self.mapped(error, host: endpoint.normalizedHost)
    }

    static func mapped(_ error: any Error, host: String) -> any Error {
        if error is CancellationError || error is CompanionError { return error }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cancelled: return CancellationError()
            case .appTransportSecurityRequiresSecureConnection:
                return CompanionError.insecureAddressBlocked(host: host)
            case .timedOut: return CompanionError.timedOut(host: host)
            case .cannotFindHost, .cannotConnectToHost, .networkConnectionLost, .notConnectedToInternet,
                .dnsLookupFailed, .dataNotAllowed:
                return CompanionError.unreachable(host: host)
            case .httpTooManyRedirects, .redirectToNonExistentLocation:
                return CompanionError.redirectRefused
            default:
                return CompanionError.unreachable(host: host)
            }
        }
        return error
    }
}

/// Refuses every redirect: the answer is then the 3xx itself, which `check` turns into `redirectRefused`.
private final class RedirectRefuser: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        nil
    }
}

/// One companion download: refuses redirects, reports byte progress, and moves the finished body out of URLSession's
/// temporary file (which is deleted as soon as the delegate call returns). An error answer's small JSON body is kept
/// for its message. State sits behind a `Mutex`; URLSession calls these methods on its own serial queue.
private final class CompanionDownloadDelegate: NSObject, URLSessionDownloadDelegate, Sendable {
    struct Outcome: Sendable {
        var response: HTTPURLResponse
        var byteCount: Int64
        var errorBody: Data?
    }

    private struct State {
        var continuation: CheckedContinuation<Outcome, any Error>?
        var response: HTTPURLResponse?
        var byteCount: Int64 = 0
        var errorBody: Data?
        var failure: (any Error)?
        var lastReportedBytes: Int64 = -1
    }

    private let partURL: URL
    private let onProgress: @Sendable (DownloadProgress) -> Void
    private let state = Mutex(State())

    init(partURL: URL, onProgress: @escaping @Sendable (DownloadProgress) -> Void) {
        self.partURL = partURL
        self.onProgress = onProgress
    }

    func attach(_ continuation: CheckedContinuation<Outcome, any Error>) {
        state.withLock { $0.continuation = continuation }
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
    ) {
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil
        let shouldReport = state.withLock { state -> Bool in
            // Every 256 KB (or the end), so the row's line moves without flooding the UI.
            guard totalBytesWritten - state.lastReportedBytes >= 256 * 1_024 || totalBytesWritten == total else {
                return false
            }
            state.lastReportedBytes = totalBytesWritten
            return true
        }
        if shouldReport {
            onProgress(DownloadProgress(bytesReceived: totalBytesWritten, totalBytes: total))
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let http = downloadTask.response as? HTTPURLResponse else {
            state.withLock { $0.failure = CompanionError.invalidResponse }
            return
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: location.path)[.size] as? NSNumber)?.int64Value
        if (200...299).contains(http.statusCode) {
            do {
                try FileManager.default.moveItem(at: location, to: partURL)
                state.withLock {
                    $0.response = http
                    $0.byteCount = size ?? 0
                }
            } catch {
                state.withLock { $0.failure = CompanionError.writeFailed(error.localizedDescription) }
            }
        } else {
            // An error answer is small JSON; read at most 64 KB of it for the message.
            let body = (try? FileHandle(forReadingFrom: location)).flatMap { handle -> Data? in
                defer { try? handle.close() }
                return try? handle.read(upToCount: 64 * 1_024)
            }
            state.withLock {
                $0.response = http
                $0.errorBody = body ?? Data()
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let (continuation, result) = state.withLock {
            state -> (CheckedContinuation<Outcome, any Error>?, Result<Outcome, any Error>) in
            let continuation = state.continuation
            state.continuation = nil
            if let failure = state.failure {
                return (continuation, .failure(failure))
            }
            if let error {
                return (continuation, .failure(error))
            }
            guard let response = state.response ?? (task.response as? HTTPURLResponse) else {
                return (continuation, .failure(CompanionError.invalidResponse))
            }
            return (
                continuation,
                .success(Outcome(response: response, byteCount: state.byteCount, errorBody: state.errorBody))
            )
        }
        if case .success(let outcome) = result, (200...299).contains(outcome.response.statusCode) {
            onProgress(DownloadProgress(bytesReceived: outcome.byteCount, totalBytes: outcome.byteCount))
        }
        continuation?.resume(with: result)
    }
}
