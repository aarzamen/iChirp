import ChirpCore
import ChirpIngest
import ChirpText
import Foundation

/// A link resolved on the person's Transcribe tap, before any row exists.
public enum ResolvedLink: Sendable, Equatable {
    /// Audio or video to download, then transcribe with the file pipeline.
    case media(LinkMediaSource)
    /// A YouTube video's captions (no audio).
    case youtubeCaptions(videoID: String, link: URL)
}

/// What to download for a link, and what the Library shows about it.
public struct LinkMediaSource: Sendable, Equatable {
    /// The audio or video file itself (a podcast's enclosure, or the pasted link).
    public var downloadURL: URL
    /// The link the person pasted; stored as `sourceURL`.
    public var link: URL
    /// `.podcast` for podcast episodes, `.url` for direct media.
    public var sourceType: Transcription.SourceType
    /// The episode's own title, when the source published one; stored as `sourceTitle`.
    public var title: String?
    /// The duration the source declared (replaced by the real one once transcribed).
    public var durationMs: Int?

    public init(
        downloadURL: URL, link: URL, sourceType: Transcription.SourceType, title: String? = nil, durationMs: Int? = nil
    ) {
        self.downloadURL = downloadURL
        self.link = link
        self.sourceType = sourceType
        self.title = title
        self.durationMs = durationMs
    }
}

/// Link failures that are not network or server errors.
public enum LinkIngestError: Error, Equatable, LocalizedError {
    /// The classifier or the probe refused the link; the message says why.
    case unsupported(String)
    /// A Retry for a row that has no link to download again.
    case missingLink

    public var errorDescription: String? {
        switch self {
        case .unsupported(let message): message
        case .missingLink: "This item has no link to download again. Delete it and paste the link again."
        }
    }
}

/// How a link download ended.
public enum LinkDownloadResult: Sendable, Equatable {
    /// The file is in `media/<id>/`, recorded on the row, which is still `.processing`: run the file pipeline next.
    case ready
    /// The download failed or was cancelled (the row as it ended), or the row was deleted meanwhile (nil).
    case ended(Transcription?)
}

/// Podcast, feed, direct-media and web links (M5 Steps 1–2): resolves a link on the person's tap, creates the row, and
/// downloads its media into `media/<id>/source.<ext>` with real progress, before the unchanged file pipeline runs.
///
/// Network happens only here, only after a tap (Transcribe or Retry), and only the link and ids derived from it are
/// sent. Downloads never hold a speech-scheduler slot: `download` finishes first and the caller then runs
/// `FileTranscriptionPipeline.process(id:)`. A failed or cancelled download leaves its row `failed`/`cancelled` with
/// the partial file kept, and Retry resumes it (`retryDownload`).
public actor LinkIngestService {
    private let paths: AppPaths
    private let store: any TranscriptionStoring
    private let http: IngestHTTPClient
    private let downloader: any MediaDownloading
    private let podcasts: any PodcastResolving
    private let onProgress: @Sendable (UUID, JobProgress) -> Void
    private let logger = Log.logger("links")

    /// - Parameter onProgress: download progress (`.downloading`), usually `TranscriptionJobCenter.progressHandler`.
    public init(
        paths: AppPaths,
        store: any TranscriptionStoring,
        http: IngestHTTPClient,
        downloader: any MediaDownloading,
        podcasts: any PodcastResolving,
        onProgress: @escaping @Sendable (UUID, JobProgress) -> Void
    ) {
        self.paths = paths
        self.store = store
        self.http = http
        self.downloader = downloader
        self.podcasts = podcasts
        self.onProgress = onProgress
    }

    // MARK: - Resolve (network, on the person's tap; no row yet)

    /// Resolves `kind` to what to fetch: the podcast lookup, the feed read, or the web link's content-type probe.
    /// Throws a readable error, with nothing created, when the link cannot be used.
    public func resolve(_ kind: LinkKind) async throws -> ResolvedLink {
        switch kind {
        case .applePodcastEpisode(let showID, let episodeID, let url):
            let episode = try await podcasts.resolveApplePodcast(showID: showID, episodeID: episodeID, link: url)
            return .media(try Self.source(for: episode, link: url))
        case .applePodcastShow(let showID, let url):
            let episode = try await podcasts.resolveApplePodcast(showID: showID, episodeID: nil, link: url)
            return .media(try Self.source(for: episode, link: url))
        case .podcastFeed(let url):
            return .media(try Self.source(for: try await podcasts.latestEpisode(inFeed: url), link: url))
        case .directMedia(let url):
            return .media(LinkMediaSource(downloadURL: url, link: url, sourceType: .url))
        case .youtube(let videoID, let url):
            return .youtubeCaptions(videoID: videoID, link: url)
        case .webLink(let url):
            let probe = try await http.probe(url)
            switch probe.kind {
            case .media:
                return .media(LinkMediaSource(downloadURL: probe.finalURL, link: url, sourceType: .url))
            case .feed:
                let episode = try await podcasts.latestEpisode(inFeed: probe.finalURL)
                return .media(try Self.source(for: episode, link: url))
            case .webPage:
                logger.notice("link_refused reason=web_page")
                throw LinkIngestError.unsupported(
                    "That link is a web page, not audio or video. Share the episode or file link instead.")
            }
        case .unsupported(let reason):
            throw LinkIngestError.unsupported(reason.message)
        }
    }

    // MARK: - Row and download

    /// Inserts the `.processing` row for `source` (link, title, source type) and returns its id. No network.
    public func createRow(for source: LinkMediaSource) async throws -> UUID {
        let id = UUID()
        var row = Transcription(
            id: id, sourceType: source.sourceType, fileName: Self.fileName(for: source),
            durationMs: source.durationMs, status: .processing)
        row.sourceURL = source.link.absoluteString
        row.sourceTitle = source.title
        try await store.insert(row)
        onProgress(id, JobProgress(stage: .downloading, fraction: 0))
        logger.info(
            "link_row_created id=\(id, privacy: .public) source=\(source.sourceType.rawValue, privacy: .public)")
        return id
    }

    /// Downloads `url` into `media/<id>/` (resuming a partial download of the same URL) and records the file on the
    /// row. Failures end the row `failed` with a readable message; cancelling ends it `cancelled`. Both keep the
    /// partial file for Retry.
    public func download(id: UUID, from url: URL) async -> LinkDownloadResult {
        let directory = paths.mediaDirectory(for: id)
        let onProgress = self.onProgress
        do {
            let file = try await downloader.download(from: url, into: directory, fileStem: "source") { progress in
                if let fraction = progress.fraction {
                    onProgress(id, JobProgress(stage: .downloading, fraction: fraction))
                }
            }
            // A finished file is always recorded, even if the job was cancelled meanwhile: the pipeline then ends the
            // row `cancelled`, and Retry transcribes it without downloading again.
            guard let relativePath = paths.relativePath(for: file.fileURL) else {
                throw CocoaError(.fileWriteInvalidFileName)
            }
            let store = self.store
            let saved = try await Self.detached { () -> Transcription? in
                guard var row = try await store.fetch(id: id) else { return nil }
                row.mediaRelativePath = relativePath
                row.fileSizeBytes = Int(clamping: file.byteCount)
                row.fileName = Self.fileName(row.fileName, withExtension: file.fileURL.pathExtension)
                return try await store.savePreservingUserMetadata(row)
            }
            guard saved != nil else {
                // Deleted during the download: the person's delete wins, the file goes with it.
                logger.notice("link_row_deleted_during_download id=\(id, privacy: .public)")
                try? FileManager.default.removeItem(at: directory)
                return .ended(nil)
            }
            logger.info("link_download_ready id=\(id, privacy: .public) resumed=\(file.resumed, privacy: .public)")
            return .ready
        } catch {
            if error is CancellationError || Task.isCancelled {
                logger.notice("link_download_cancelled id=\(id, privacy: .public)")
                return .ended(await markEnded(id, status: .cancelled, message: nil))
            }
            let message = Self.readable(error)
            logger.error(
                "link_download_failed id=\(id, privacy: .public) error_type=\(String(describing: type(of: error)), privacy: .public)"
            )
            return .ended(await markEnded(id, status: .failed, message: message))
        }
    }

    /// Retry for a link row whose download never finished (`needsDownload`): moves it back to `.processing` and
    /// downloads again, resuming the partial file when the server allows. The URL comes from the partial download's
    /// record, else the stored link is resolved again (a new tap, so the network is allowed).
    public func retryDownload(id: UUID) async -> LinkDownloadResult {
        let store = self.store
        let reset = try? await Self.detached {
            try await store.transitionStatus(
                id: id, from: [.failed, .cancelled, .interrupted], to: .processing, errorMessage: nil)
        }
        guard let row = reset ?? nil else {
            return .ended(try? await store.fetch(id: id))
        }
        onProgress(id, JobProgress(stage: .downloading, fraction: 0))
        do {
            let url = try await downloadURL(for: row)
            return await download(id: id, from: url)
        } catch {
            if error is CancellationError || Task.isCancelled {
                return .ended(await markEnded(id, status: .cancelled, message: nil))
            }
            return .ended(await markEnded(id, status: .failed, message: Self.readable(error)))
        }
    }

    /// Whether Retry for `row` must download again (a link row whose media never arrived) rather than re-transcribe.
    public static func needsDownload(_ row: Transcription) -> Bool {
        (row.sourceType == .podcast || row.sourceType == .url) && row.sourceURL != nil && row.mediaRelativePath == nil
    }

    /// The runnable job for a new or retried link row: the download, then (once the file is in place) `transcribe`.
    public static func downloadThenTranscribe(
        _ download: LinkDownloadResult,
        transcribe: @Sendable () async -> Transcription?
    ) async -> Transcription? {
        switch download {
        case .ready: await transcribe()
        case .ended(let row): row
        }
    }

    private func downloadURL(for row: Transcription) async throws -> URL {
        let infoURL = paths.mediaDirectory(for: row.id)
            .appendingPathComponent(MediaDownloader.partialInfoFileName, isDirectory: false)
        if let data = try? Data(contentsOf: infoURL),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let string = object["url"] as? String, let url = URL(string: string)
        {
            return url
        }
        guard let link = row.sourceURL else { throw LinkIngestError.missingLink }
        switch try await resolve(LinkClassifier.classify(link)) {
        case .media(let source): return source.downloadURL
        case .youtubeCaptions: throw LinkIngestError.missingLink
        }
    }

    // MARK: - Helpers

    /// Moves a `.processing` row to `status`, outside the job's cancellation (the store refuses writes from a
    /// cancelled task). Returns the row as stored, or nil when it is gone.
    private func markEnded(_ id: UUID, status: Transcription.Status, message: String?) async -> Transcription? {
        let store = self.store
        do {
            if let ended = try await Self.detached({
                try await store.transitionStatus(id: id, from: [.processing], to: status, errorMessage: message)
            }) {
                return ended
            }
            return try await Self.detached { try await store.fetch(id: id) }
        } catch {
            logger.error(
                "link_status_write_failed id=\(id, privacy: .public) error_type=\(String(describing: type(of: error)), privacy: .public)"
            )
            return nil
        }
    }

    static func source(for episode: ResolvedPodcastEpisode, link: URL) throws -> LinkMediaSource {
        let trimmed = episode.audioURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            let url = URL(string: trimmed)
                ?? trimmed.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed).flatMap(URL.init),
            let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https"
        else {
            throw PodcastResolveError.noPlayableAudio
        }
        return LinkMediaSource(
            downloadURL: url, link: link, sourceType: .podcast, title: episode.episodeTitle,
            durationMs: episode.durationSeconds.map { $0 * 1000 })
    }

    /// The row's file name before the download: the episode title, else the link's last path component.
    static func fileName(for source: LinkMediaSource) -> String {
        if let title = source.title.map(sanitizedFileStem), !title.isEmpty {
            return title
        }
        let last = source.downloadURL.lastPathComponent
        return last.isEmpty || last == "/" ? (source.downloadURL.host() ?? "Download") : last
    }

    /// `name` with `ext` as its extension (replacing a media extension it already had).
    static func fileName(_ name: String, withExtension ext: String) -> String {
        let current = (name as NSString).pathExtension.lowercased()
        let stem = LinkClassifier.mediaExtensions.contains(current) ? (name as NSString).deletingPathExtension : name
        return ext.isEmpty ? stem : "\(stem).\(ext)"
    }

    /// A title made safe as a file name: no slashes, colons or control characters, at most 120 characters.
    static func sanitizedFileStem(_ raw: String) -> String {
        var disallowed = CharacterSet(charactersIn: "/:\\\"")
        disallowed.formUnion(.controlCharacters)
        let cleaned = raw.components(separatedBy: disallowed).joined(separator: " ")
            .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        return String(cleaned.prefix(120)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func readable(_ error: any Error) -> String {
        if let description = (error as? any LocalizedError)?.errorDescription, !description.isEmpty {
            return description
        }
        return error.localizedDescription
    }

    /// Runs `operation` in a new unstructured task: it keeps the caller's priority but not its cancellation, so
    /// terminal writes land (GRDB's async accessors throw inside a cancelled task).
    private static func detached<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await Task { try await operation() }.value
    }
}
