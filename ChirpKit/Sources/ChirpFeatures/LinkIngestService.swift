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

/// How a link's media reaches this iPhone.
public enum LinkTransport: String, Sendable, Equatable {
    /// Downloaded here, from `downloadURL`.
    case direct
    /// Fetched by the owner's Mac companion (a YouTube video without captions, plan 019): only the link is sent to
    /// the Mac, which downloads the audio from YouTube and sends it back.
    case companion
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
    /// `.direct` downloads `downloadURL` here; `.companion` asks the Mac companion for the link's audio.
    public var transport: LinkTransport

    public init(
        downloadURL: URL, link: URL, sourceType: Transcription.SourceType, title: String? = nil, durationMs: Int? = nil,
        transport: LinkTransport = .direct
    ) {
        self.downloadURL = downloadURL
        self.link = link
        self.sourceType = sourceType
        self.title = title
        self.durationMs = durationMs
        self.transport = transport
    }

    /// A YouTube video's audio through the Mac companion (plan 019). `downloadURL` is the canonical
    /// `https://www.youtube.com/watch?v=<id>` rebuilt from the validated id, the only form sent to the Mac (share
    /// parameters such as `si=` and `list=` stay on the phone); `link` keeps the pasted link for the row.
    public static func companionYouTube(_ link: URL) -> LinkMediaSource {
        LinkMediaSource(
            downloadURL: YouTubeURLValidator.canonicalWatchURL(link.absoluteString) ?? link, link: link,
            sourceType: .url, transport: .companion)
    }
}

/// Link failures that are not network or server errors.
public enum LinkIngestError: Error, Equatable, LocalizedError {
    /// The classifier or the probe refused the link; the message says why.
    case unsupported(String)
    /// A Retry for a row that has no link to download again.
    case missingLink
    /// YouTube audio needs the Mac companion, and none is set up (or it has no pairing token).
    case companionNotConfigured
    /// Retry would send the link to a Mac the owner has not confirmed it for (Settings → Mac companion changed, or
    /// the app restarted): the app asks first (`LinkIngestService.companionRetryConfirmationHost`).
    case companionNotConfirmed

    public var errorDescription: String? {
        switch self {
        case .unsupported(let message): message
        case .missingLink: "This item has no link to download again. Delete it and paste the link again."
        case .companionNotConfigured:
            "Getting a YouTube video’s audio needs the Mac companion. Set it up in Settings → Mac companion."
        case .companionNotConfirmed:
            "Tap Retry and confirm sending this link to your Mac."
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
    private let captions: any YouTubeCaptionFetching
    private let companion: @Sendable () -> (any CompanionAudioFetching)?
    private let preferredLanguages: @Sendable () -> [String]
    private let onProgress: @Sendable (UUID, JobProgress) -> Void
    private let logger = Log.logger("links")
    /// Row id → the companion its link was confirmed for, in this launch (the Paste a link sheet's question, or a
    /// Retry's). A Retry to any other companion, or after a restart, asks again (review L1 M2).
    private var confirmedCompanions: [UUID: CompanionEndpoint] = [:]

    /// - Parameters:
    ///   - preferredLanguages: language codes for choosing a YouTube caption track (the device's languages).
    ///   - onProgress: download progress (`.downloading`), usually `TranscriptionJobCenter.progressHandler`.
    ///   - companion: the Mac companion's client, read at each use (nil when none is set up with a pairing token).
    public init(
        paths: AppPaths,
        store: any TranscriptionStoring,
        http: IngestHTTPClient,
        downloader: any MediaDownloading,
        podcasts: any PodcastResolving,
        captions: any YouTubeCaptionFetching,
        companion: @escaping @Sendable () -> (any CompanionAudioFetching)? = { nil },
        preferredLanguages: @escaping @Sendable () -> [String] = { Locale.preferredLanguages },
        onProgress: @escaping @Sendable (UUID, JobProgress) -> Void
    ) {
        self.paths = paths
        self.store = store
        self.http = http
        self.downloader = downloader
        self.podcasts = podcasts
        self.captions = captions
        self.companion = companion
        self.preferredLanguages = preferredLanguages
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
        // The size is unknown until the server answers: "Downloading…", not "0%".
        onProgress(id, .indeterminate(.downloading))
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
                onProgress(id, Self.jobProgress(progress))
            }
            // A finished file is always recorded, even if the job was cancelled meanwhile: the pipeline then ends the
            // row `cancelled`, and Retry transcribes it without downloading again.
            let recorded = try await record(
                id: id, fileURL: file.fileURL, byteCount: file.byteCount, title: nil, durationMs: nil)
            guard recorded else { return .ended(nil) }
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

    /// The download for a new link row: here (`.direct`), or through the Mac companion (`.companion`).
    /// A `.companion` source was confirmed in the Paste a link sheet for the companion set up now.
    public func download(id: UUID, source: LinkMediaSource) async -> LinkDownloadResult {
        switch source.transport {
        case .direct:
            return await download(id: id, from: source.downloadURL)
        case .companion:
            if let endpoint = companion()?.endpoint { confirmedCompanions[id] = endpoint }
            return await downloadFromCompanion(id: id, link: source.downloadURL)
        }
    }

    // MARK: - YouTube audio through the Mac companion (plan 019)

    /// Whether a Mac companion is set up with a pairing token (the Paste a link sheet then offers YouTube audio).
    public nonisolated func isCompanionConfigured() -> Bool {
        companion() != nil
    }

    /// Sends the YouTube video's canonical link (`https://www.youtube.com/watch?v=<id>`, rebuilt here from `link`'s
    /// validated id) to the Mac companion, which downloads the audio and sends it back into `media/<id>/source.m4a`;
    /// records the file, the video's title and duration on the row. Only that link leaves this iPhone (the person
    /// confirmed it for this Mac). Failures end the row `failed` with the companion's sentence; cancelling ends it
    /// `cancelled`; Retry asks the companion again.
    public func downloadFromCompanion(id: UUID, link: URL) async -> LinkDownloadResult {
        guard let companion = companion() else {
            logger.notice("companion_download_refused id=\(id, privacy: .public) reason=not_configured")
            return .ended(
                await markEnded(id, status: .failed, message: LinkIngestError.companionNotConfigured.errorDescription))
        }
        guard let canonical = YouTubeURLValidator.canonicalWatchURL(link.absoluteString) else {
            logger.notice("companion_download_refused id=\(id, privacy: .public) reason=not_a_video_link")
            return .ended(
                await markEnded(
                    id, status: .failed,
                    message: LinkIngestError.unsupported("That is not a link to a single YouTube video.")
                        .errorDescription))
        }
        guard Self.sameCompanion(confirmedCompanions[id], companion.endpoint) else {
            logger.notice("companion_download_refused id=\(id, privacy: .public) reason=not_confirmed")
            return .ended(
                await markEnded(id, status: .failed, message: LinkIngestError.companionNotConfirmed.errorDescription))
        }
        let directory = paths.mediaDirectory(for: id)
        let onProgress = self.onProgress
        onProgress(id, .indeterminate(.downloading))
        do {
            let audio = try await companion.youtubeAudio(url: canonical, into: directory, fileStem: "source") {
                progress in
                onProgress(id, Self.jobProgress(progress))
            }
            let recorded = try await record(
                id: id, fileURL: audio.fileURL, byteCount: audio.byteCount, title: audio.title,
                durationMs: audio.durationMs)
            guard recorded else { return .ended(nil) }
            logger.info(
                "companion_download_ready id=\(id, privacy: .public) bytes=\(audio.byteCount, privacy: .public)")
            return .ready
        } catch {
            if error is CancellationError || Task.isCancelled {
                logger.notice("companion_download_cancelled id=\(id, privacy: .public)")
                return .ended(await markEnded(id, status: .cancelled, message: nil))
            }
            logger.error(
                "companion_download_failed id=\(id, privacy: .public) error_type=\(String(describing: type(of: error)), privacy: .public)"
            )
            return .ended(await markEnded(id, status: .failed, message: Self.readable(error)))
        }
    }

    /// The companion host a Retry of row `id` would send its link to, when the person has not confirmed that link for
    /// that companion in this launch (Settings → Mac companion points at another Mac, or the app restarted): the app
    /// asks "Send this link to your Mac?" first. nil when no question is needed (not a YouTube row, no companion, or
    /// already confirmed for it).
    public func companionRetryConfirmationHost(id: UUID) async -> String? {
        guard let row = try? await store.fetch(id: id), let link = row.sourceURL,
            YouTubeURLValidator.isYouTubeURL(link), let endpoint = companion()?.endpoint
        else { return nil }
        return Self.sameCompanion(confirmedCompanions[id], endpoint) ? nil : endpoint.normalizedHost
    }

    /// The person confirmed sending row `id`'s link to the companion set up now (the Retry question).
    public func confirmCompanionRetry(id: UUID) {
        guard let endpoint = companion()?.endpoint else { return }
        confirmedCompanions[id] = endpoint
    }

    static func sameCompanion(_ confirmed: CompanionEndpoint?, _ current: CompanionEndpoint) -> Bool {
        guard let confirmed else { return false }
        return confirmed.normalizedHost == current.normalizedHost && confirmed.port == current.port
    }

    /// Download progress as a job's progress: a fraction when the size is known, else "Downloading…".
    static func jobProgress(_ progress: DownloadProgress) -> JobProgress {
        if let fraction = progress.fraction {
            return JobProgress(stage: .downloading, fraction: fraction)
        }
        return .indeterminate(.downloading)
    }

    /// Records a finished file on the row (path, size, file name; and the source's title and duration when given).
    /// Returns false when the row was deleted meanwhile: the person's delete wins and the file goes with it.
    private func record(id: UUID, fileURL: URL, byteCount: Int64, title: String?, durationMs: Int?) async throws
        -> Bool
    {
        guard let relativePath = paths.relativePath(for: fileURL) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        let store = self.store
        let saved = try await Self.detached { () -> Transcription? in
            guard var row = try await store.fetch(id: id) else { return nil }
            row.mediaRelativePath = relativePath
            row.fileSizeBytes = Int(clamping: byteCount)
            if let title, !title.isEmpty {
                row.sourceTitle = title
                let stem = Self.sanitizedFileStem(title)
                if !stem.isEmpty { row.fileName = stem }
            }
            if let durationMs, durationMs > 0 { row.durationMs = durationMs }
            row.fileName = Self.fileName(row.fileName, withExtension: fileURL.pathExtension)
            return try await store.savePreservingUserMetadata(row)
        }
        guard saved != nil else {
            logger.notice("link_row_deleted_during_download id=\(id, privacy: .public)")
            try? FileManager.default.removeItem(at: paths.mediaDirectory(for: id))
            return false
        }
        return true
    }

    // MARK: - Retry

    /// Retry for a link row whose download never finished (`needsDownload`): moves it back to `.processing` and
    /// downloads again, resuming the partial file when the server allows. The URL comes from the partial download's
    /// record, else the stored link is resolved again (a new tap, so the network is allowed). A YouTube row goes back
    /// to the Mac companion, only while it is the companion the person confirmed that link for (else the row fails
    /// with `companionNotConfirmed`; the app asks first with `companionRetryConfirmationHost`).
    public func retryDownload(id: UUID) async -> LinkDownloadResult {
        let store = self.store
        let reset = try? await Self.detached {
            try await store.transitionStatus(
                id: id, from: [.failed, .cancelled, .interrupted], to: .processing, errorMessage: nil)
        }
        guard let row = reset ?? nil else {
            return .ended(try? await store.fetch(id: id))
        }
        onProgress(id, .indeterminate(.downloading))
        if let link = row.sourceURL.flatMap(URL.init(string:)),
            case .youtube = LinkClassifier.classify(link.absoluteString)
        {
            return await downloadFromCompanion(id: id, link: link)
        }
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

    // MARK: - YouTube captions (M5 Step 3)

    /// The engine id a caption row records (`Transcription.engine`); `engineVariant` is "manual" or "asr".
    public static let captionsEngineID = "youtube.captions"

    /// Fetches the video's captions (network, on the person's tap) and inserts a `.completed` `.url` row: the caption
    /// words with timings spread across each caption, segments, the video's title, no audio. Throws a readable error,
    /// with no row created, when the video has no usable captions.
    public func importCaptions(videoID: String, link: URL) async throws -> UUID {
        let fetched = try await captions.fetchCaptions(videoID: videoID, preferredLanguages: preferredLanguages())
        let words = Self.words(from: fetched.cues)
        guard !words.isEmpty else { throw YouTubeCaptionError.emptyTranscript }
        let text = fetched.cues.map(\.text).joined(separator: " ")
        let id = UUID()
        let lastEnd = words.map(\.endMs).max() ?? 0
        var row = Transcription(
            id: id, sourceType: .url,
            fileName: fetched.title.map(Self.sanitizedFileStem).flatMap { $0.isEmpty ? nil : $0 }
                ?? "YouTube video",
            durationMs: fetched.lengthSeconds.map { max($0 * 1000, lastEnd) } ?? lastEnd,
            status: .completed)
        row.sourceURL = link.absoluteString
        row.sourceTitle = fetched.title
        row.rawTranscript = text
        row.wordTimestamps = words
        row.language = fetched.track.languageCode.isEmpty ? nil : fetched.track.languageCode
        row.engine = Self.captionsEngineID
        row.engineVariant = fetched.track.isGenerated ? "asr" : "manual"
        let title = TitleDeriver.derive(from: text) ?? ""
        row.derivedTitle = title
        row.derivedSnippet = SnippetDeriver.derive(from: text, excluding: title) ?? ""
        let segments = FileTranscriptSegments.materialize(words: words)
        row.transcriptSegments = segments.isEmpty ? nil : segments
        try await store.insert(row)
        logger.info(
            "captions_row_created id=\(id, privacy: .public) words=\(words.count, privacy: .public) generated=\(fetched.track.isGenerated, privacy: .public)"
        )
        return id
    }

    /// Caption cues as words: each cue's words share its time span in proportion to their length. A cue that runs
    /// past the next cue's start (automatic captions overlap) ends where the next begins, so times never go back.
    public static func words(from cues: [CaptionCue]) -> [WordTimestamp] {
        let sorted = cues.sorted { $0.startMs < $1.startMs }
        var words: [WordTimestamp] = []
        for (index, cue) in sorted.enumerated() {
            let tokens = cue.text.split(whereSeparator: \.isWhitespace).map(String.init)
            guard !tokens.isEmpty else { continue }
            let start = max(cue.startMs, words.last?.endMs ?? 0)
            var end = cue.startMs + max(cue.durationMs, 1)
            if index + 1 < sorted.count {
                end = min(end, max(sorted[index + 1].startMs, start + 1))
            }
            end = max(end, start + tokens.count)
            let span = Double(end - start)
            let totalCharacters = Double(tokens.reduce(0) { $0 + $1.count })
            var cursor = Double(start)
            for token in tokens {
                let length = span * Double(token.count) / totalCharacters
                let wordStart = Int(cursor.rounded())
                cursor += length
                let wordEnd = max(wordStart + 1, Int(cursor.rounded()))
                words.append(WordTimestamp(word: token, startMs: wordStart, endMs: min(wordEnd, end), confidence: 1))
            }
        }
        return words
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

    /// The row's file name before the download: the episode title, else the link's last path component ("YouTube
    /// video" for a companion download, whose title arrives with the audio).
    static func fileName(for source: LinkMediaSource) -> String {
        if let title = source.title.map(sanitizedFileStem), !title.isEmpty {
            return title
        }
        if source.transport == .companion {
            return "YouTube video"
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
