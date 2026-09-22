// Semantics from MacParakeet (GPL-3.0): Sources/MacParakeetCore/Services/PodcastAudioDownloader.swift @ bbae9e0e —
// byte progress from Content-Length, an audio User-Agent/Accept pair, and `fileExtension(for:response:)` (extended
// here with video types). Fresh implementation, not a line port: the body streams into the item's own media folder
// through a data-task delegate so an interrupted download can resume with `Range`/`If-Range` on Retry.

import ChirpCore
import Foundation
import Synchronization

/// Bytes received so far, and the total when the server said it.
public struct DownloadProgress: Sendable, Equatable {
    public var bytesReceived: Int64
    public var totalBytes: Int64?

    public init(bytesReceived: Int64, totalBytes: Int64?) {
        self.bytesReceived = bytesReceived
        self.totalBytes = totalBytes
    }

    /// 0…1 when the total is known; nil otherwise (the UI then shows the bytes, never a made-up percentage).
    public var fraction: Double? {
        guard let totalBytes, totalBytes > 0 else { return nil }
        return min(1, max(0, Double(bytesReceived) / Double(totalBytes)))
    }
}

/// A finished download.
public struct DownloadedFile: Sendable, Equatable {
    /// `<directory>/<stem>.<ext>`.
    public var fileURL: URL
    public var mimeType: String?
    public var byteCount: Int64
    /// Whether the body continued an earlier partial download.
    public var resumed: Bool

    public init(fileURL: URL, mimeType: String?, byteCount: Int64, resumed: Bool) {
        self.fileURL = fileURL
        self.mimeType = mimeType
        self.byteCount = byteCount
        self.resumed = resumed
    }
}

public enum MediaDownloadError: Error, Equatable, LocalizedError {
    case invalidURL
    /// The server sent a web page or text instead of audio or video.
    case notMedia(contentType: String)
    case emptyFile
    case writeFailed(String)
    /// The server answered a resume request with bytes that do not continue the partial file.
    case resumeMismatch

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            "The media link is not a valid web address."
        case .notMedia:
            "That link is a web page, not an audio or video file. Share the episode or file link instead."
        case .emptyFile:
            "The server sent an empty file."
        case .writeFailed(let reason):
            "Couldn’t save the download on this iPhone: \(reason)"
        case .resumeMismatch:
            "The server could not continue the earlier download."
        }
    }
}

/// Downloads a media file into a folder, with progress, cancellation and resume.
public protocol MediaDownloading: Sendable {
    /// Downloads `url` into `directory` as `<fileStem>.<ext>` (the extension from the link or its content type).
    ///
    /// While running, the body lives in `directory/download.part` next to a small `download.part.json`. Cancelling
    /// (or a network failure) keeps both, and a later call for the same URL resumes from where it stopped when the
    /// server supports ranges and the file has not changed; otherwise it starts over. `progress` is called from any
    /// thread.
    func download(
        from url: URL,
        into directory: URL,
        fileStem: String,
        progress: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws -> DownloadedFile
}

/// `MediaDownloading` on `URLSession`. Never runs inside a speech-scheduler slot: callers download first and hand the
/// finished file to the transcription pipeline.
public final class MediaDownloader: MediaDownloading {
    public static let partialFileName = "download.part"
    public static let partialInfoFileName = "download.part.json"
    /// Extensions a finished file may keep from its link.
    static let knownExtensions: Set<String> = LinkClassifier.mediaExtensions

    private let makeConfiguration: @Sendable () -> URLSessionConfiguration
    private let logger = Log.logger("download")

    /// - Parameter configuration: builds each download's session configuration (tests add a `URLProtocol` stub).
    public init(
        configuration: @escaping @Sendable () -> URLSessionConfiguration = { IngestHTTPClient.privateConfiguration() }
    ) {
        self.makeConfiguration = configuration
    }

    public func download(
        from url: URL,
        into directory: URL,
        fileStem: String = "source",
        progress: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws -> DownloadedFile {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw MediaDownloadError.invalidURL
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw MediaDownloadError.writeFailed(error.localizedDescription)
        }
        let partURL = directory.appendingPathComponent(Self.partialFileName, isDirectory: false)
        let infoURL = directory.appendingPathComponent(Self.partialInfoFileName, isDirectory: false)

        var restarted = false
        while true {
            let resume = Self.resumePoint(partURL: partURL, infoURL: infoURL, for: url)
            if resume == nil {
                try? FileManager.default.removeItem(at: partURL)
                try? FileManager.default.removeItem(at: infoURL)
            }
            do {
                let outcome = try await transfer(
                    url: url, partURL: partURL, infoURL: infoURL, resume: resume, progress: progress)
                return try finish(outcome, url: url, directory: directory, fileStem: fileStem, infoURL: infoURL)
            } catch MediaDownloadError.resumeMismatch where !restarted {
                // The server does not continue this file: start over once, from zero.
                logger.notice("download_resume_refused restarting=true")
                restarted = true
                try? FileManager.default.removeItem(at: partURL)
                try? FileManager.default.removeItem(at: infoURL)
            }
        }
    }

    // MARK: - Transfer

    struct ResumePoint: Equatable {
        var offset: Int64
        var validator: String
    }

    struct Outcome: Sendable {
        var response: HTTPURLResponse
        var byteCount: Int64
        var resumed: Bool
    }

    private func transfer(
        url: URL,
        partURL: URL,
        infoURL: URL,
        resume: ResumePoint?,
        progress: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws -> Outcome {
        var request = URLRequest(url: url)
        request.setValue(IngestHTTPClient.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("audio/*, video/*, application/octet-stream;q=0.9, */*;q=0.8", forHTTPHeaderField: "Accept")
        if let resume {
            request.setValue("bytes=\(resume.offset)-", forHTTPHeaderField: "Range")
            request.setValue(resume.validator, forHTTPHeaderField: "If-Range")
        }
        let delegate = DownloadDelegate(
            url: url, partURL: partURL, infoURL: infoURL, resumeOffset: resume?.offset ?? 0, onProgress: progress)
        let session = URLSession(configuration: makeConfiguration(), delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = session.dataTask(with: request)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delegate.attach(continuation)
                if Task.isCancelled {
                    task.cancel()
                }
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    private func finish(
        _ outcome: Outcome,
        url: URL,
        directory: URL,
        fileStem: String,
        infoURL: URL
    ) throws -> DownloadedFile {
        let partURL = directory.appendingPathComponent(Self.partialFileName, isDirectory: false)
        guard outcome.byteCount > 0 else {
            try? FileManager.default.removeItem(at: partURL)
            try? FileManager.default.removeItem(at: infoURL)
            throw MediaDownloadError.emptyFile
        }
        let fileExtension = Self.fileExtension(for: outcome.response.url ?? url, mimeType: outcome.response.mimeType)
        let destination = directory.appendingPathComponent("\(fileStem).\(fileExtension)", isDirectory: false)
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: partURL, to: destination)
        } catch {
            throw MediaDownloadError.writeFailed(error.localizedDescription)
        }
        try? FileManager.default.removeItem(at: infoURL)
        logger.info(
            "download_finished bytes=\(outcome.byteCount, privacy: .public) resumed=\(outcome.resumed, privacy: .public) ext=\(fileExtension, privacy: .public)"
        )
        return DownloadedFile(
            fileURL: destination, mimeType: outcome.response.mimeType?.lowercased(), byteCount: outcome.byteCount,
            resumed: outcome.resumed)
    }

    // MARK: - Resume bookkeeping

    /// What `download.part.json` records: enough to ask the server for the rest of the same file.
    struct PartialInfo: Codable, Equatable {
        var url: String
        var etag: String?
        var lastModified: String?
        var totalBytes: Int64?
    }

    /// Where to resume `url`: the partial file's size and a validator (ETag or Last-Modified), or nil to start over.
    /// A strong ETag is preferred; a weak one (`W/…`) cannot be used with If-Range.
    static func resumePoint(partURL: URL, infoURL: URL, for url: URL) -> ResumePoint? {
        guard let data = try? Data(contentsOf: infoURL),
            let info = try? JSONDecoder().decode(PartialInfo.self, from: data),
            info.url == url.absoluteString,
            let size = (try? FileManager.default.attributesOfItem(atPath: partURL.path)[.size] as? NSNumber)?
                .int64Value,
            size > 0
        else {
            return nil
        }
        if let total = info.totalBytes, size >= total {
            return nil
        }
        if let etag = info.etag, !etag.hasPrefix("W/") {
            return ResumePoint(offset: size, validator: etag)
        }
        if let lastModified = info.lastModified {
            return ResumePoint(offset: size, validator: lastModified)
        }
        return nil
    }

    /// Parses `Content-Range: bytes <start>-<end>/<total|*>` into its start and total.
    static func contentRange(_ header: String?) -> (start: Int64, total: Int64?)? {
        guard let header = header?.trimmingCharacters(in: .whitespaces).lowercased(), header.hasPrefix("bytes ")
        else {
            return nil
        }
        let spec = header.dropFirst("bytes ".count)
        let parts = spec.split(separator: "/", maxSplits: 1)
        guard let rangePart = parts.first, let dash = rangePart.firstIndex(of: "-"),
            let start = Int64(rangePart[..<dash])
        else {
            return nil
        }
        let total = parts.count == 2 ? Int64(parts[1]) : nil
        return (start, total)
    }

    // MARK: - File naming

    /// The link's own media extension, else one from the content type, else "mp3" (as upstream).
    static func fileExtension(for url: URL, mimeType: String?) -> String {
        let pathExtension = url.pathExtension.lowercased()
        if knownExtensions.contains(pathExtension) {
            return pathExtension
        }
        let mime = mimeType?.lowercased() ?? ""
        let byMime: [(needle: String, ext: String)] = [
            ("mpeg", "mp3"), ("mp3", "mp3"), ("x-m4a", "m4a"), ("audio/mp4", "m4a"), ("audio/m4a", "m4a"),
            ("aac", "aac"), ("wav", "wav"), ("wave", "wav"), ("flac", "flac"), ("aiff", "aiff"),
            ("video/mp4", "mp4"), ("quicktime", "mov"), ("x-m4v", "m4v"), ("3gpp", "3gp"),
        ]
        if let match = byMime.first(where: { mime.contains($0.needle) }) {
            return match.ext
        }
        return "mp3"
    }

    /// Content types that mean "not a media file" (an error page, a web page, JSON).
    static func isNonMedia(_ mimeType: String?) -> Bool {
        guard let mime = mimeType?.lowercased() else { return false }
        return mime.hasPrefix("text/") || mime == "application/xhtml+xml" || mime == "application/json"
            || mime.contains("rss") || mime == "application/xml"
    }
}

// MARK: - Delegate

/// Streams one data task into `download.part`. All mutable state sits behind a `Mutex`; URLSession calls these methods
/// on its own serial delegate queue.
private final class DownloadDelegate: NSObject, URLSessionDataDelegate, Sendable {
    private struct State {
        var continuation: CheckedContinuation<MediaDownloader.Outcome, any Error>?
        var handle: FileHandle?
        var received: Int64 = 0
        var startOffset: Int64 = 0
        var totalBytes: Int64?
        var response: HTTPURLResponse?
        var failure: (any Error)?
        var lastReportedPermille = -1
        var lastReportedBytes: Int64 = 0
    }

    private let url: URL
    private let partURL: URL
    private let infoURL: URL
    private let resumeOffset: Int64
    private let onProgress: @Sendable (DownloadProgress) -> Void
    private let state = Mutex(State())

    init(
        url: URL, partURL: URL, infoURL: URL, resumeOffset: Int64,
        onProgress: @escaping @Sendable (DownloadProgress) -> Void
    ) {
        self.url = url
        self.partURL = partURL
        self.infoURL = infoURL
        self.resumeOffset = resumeOffset
        self.onProgress = onProgress
    }

    func attach(_ continuation: CheckedContinuation<MediaDownloader.Outcome, any Error>) {
        state.withLock { $0.continuation = continuation }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        do {
            let (startOffset, total) = try prepare(for: response)
            let report = DownloadProgress(bytesReceived: startOffset, totalBytes: total)
            onProgress(report)
            completionHandler(.allow)
        } catch {
            state.withLock { $0.failure = error }
            completionHandler(.cancel)
        }
    }

    /// Checks the status and content type, opens `download.part` (appending after a matching 206, from zero
    /// otherwise) and writes `download.part.json`. Returns the start offset and the total size when known.
    private func prepare(for response: URLResponse) throws -> (Int64, Int64?) {
        guard let http = response as? HTTPURLResponse else { throw IngestNetworkError.notHTTP }
        let fileManager = FileManager.default
        let startOffset: Int64
        let total: Int64?
        switch http.statusCode {
        case 200:
            startOffset = 0
            total = http.expectedContentLength > 0 ? http.expectedContentLength : nil
        case 206:
            guard let range = MediaDownloader.contentRange(http.value(forHTTPHeaderField: "Content-Range")),
                range.start == resumeOffset
            else {
                throw MediaDownloadError.resumeMismatch
            }
            startOffset = range.start
            total = range.total ?? (http.expectedContentLength > 0 ? range.start + http.expectedContentLength : nil)
        case 416:
            throw MediaDownloadError.resumeMismatch
        default:
            throw IngestNetworkError.httpStatus(http.statusCode)
        }
        if MediaDownloader.isNonMedia(http.mimeType) {
            throw MediaDownloadError.notMedia(contentType: http.mimeType ?? "")
        }

        let handle: FileHandle
        do {
            if startOffset == 0 || !fileManager.fileExists(atPath: partURL.path) {
                try? fileManager.removeItem(at: partURL)
                guard fileManager.createFile(atPath: partURL.path, contents: nil) else {
                    throw CocoaError(.fileWriteUnknown)
                }
            }
            handle = try FileHandle(forWritingTo: partURL)
            if startOffset > 0 {
                try handle.seekToEnd()
            }
        } catch {
            throw MediaDownloadError.writeFailed(error.localizedDescription)
        }
        let info = MediaDownloader.PartialInfo(
            url: url.absoluteString,
            etag: http.value(forHTTPHeaderField: "ETag"),
            lastModified: http.value(forHTTPHeaderField: "Last-Modified"),
            totalBytes: total)
        if let data = try? JSONEncoder().encode(info) {
            try? data.write(to: infoURL, options: .atomic)
        }
        state.withLock {
            $0.handle = handle
            $0.startOffset = startOffset
            $0.totalBytes = total
            $0.response = http
        }
        return (startOffset, total)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let report: DownloadProgress? = state.withLock { state in
            guard let handle = state.handle, state.failure == nil else { return nil }
            do {
                try handle.write(contentsOf: data)
            } catch {
                state.failure = MediaDownloadError.writeFailed(error.localizedDescription)
                return nil
            }
            state.received += Int64(data.count)
            let bytes = state.startOffset + state.received
            if let total = state.totalBytes, total > 0 {
                let permille = Int(min(1, Double(bytes) / Double(total)) * 1_000)
                guard permille != state.lastReportedPermille else { return nil }
                state.lastReportedPermille = permille
            } else {
                // Unknown total: report every 256 KB so the byte count moves.
                guard bytes - state.lastReportedBytes >= 256 * 1_024 else { return nil }
            }
            state.lastReportedBytes = bytes
            return DownloadProgress(bytesReceived: bytes, totalBytes: state.totalBytes)
        }
        if state.withLock({ $0.failure != nil }) {
            dataTask.cancel()
            return
        }
        if let report {
            onProgress(report)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let ending = state.withLock { state -> Ending in
            try? state.handle?.close()
            state.handle = nil
            let continuation = state.continuation
            state.continuation = nil
            if let failure = state.failure {
                return Ending(continuation: continuation, result: .failure(failure))
            }
            if let error {
                return Ending(continuation: continuation, result: .failure(IngestNetworkError.map(error)))
            }
            guard let response = state.response else {
                return Ending(continuation: continuation, result: .failure(IngestNetworkError.notHTTP))
            }
            let outcome = MediaDownloader.Outcome(
                response: response, byteCount: state.startOffset + state.received, resumed: state.startOffset > 0)
            return Ending(continuation: continuation, result: .success(outcome))
        }
        if case .success(let outcome) = ending.result {
            onProgress(DownloadProgress(bytesReceived: outcome.byteCount, totalBytes: outcome.byteCount))
        }
        ending.continuation?.resume(with: ending.result)
    }

    /// The task's end, taken out of the lock before resuming the waiting download.
    private struct Ending {
        var continuation: CheckedContinuation<MediaDownloader.Outcome, any Error>?
        var result: Result<MediaDownloader.Outcome, any Error>
    }
}
