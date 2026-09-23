import ChirpCore
import ChirpIngest
import Foundation
import Synchronization
import XCTest

@testable import ChirpFeatures

// MARK: - Fakes

/// Writes `payload` as `<stem>.<ext>` into the folder, or fails, or waits until cancelled. Records every URL.
final class FakeMediaDownloader: MediaDownloading {
    enum Behavior: Sendable {
        case succeed(ext: String, payload: Data)
        case fail(any Error & Sendable)
        case waitForCancel
    }

    private let state: Mutex<(behavior: Behavior, urls: [URL])>
    let started = Signal()

    init(_ behavior: Behavior) {
        state = Mutex((behavior, []))
    }

    var urls: [URL] { state.withLock { $0.urls } }

    func setBehavior(_ behavior: Behavior) {
        state.withLock { $0.behavior = behavior }
    }

    func download(
        from url: URL, into directory: URL, fileStem: String,
        progress: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws -> DownloadedFile {
        let behavior = state.withLock { state -> Behavior in
            state.urls.append(url)
            return state.behavior
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        switch behavior {
        case .succeed(let ext, let payload):
            progress(DownloadProgress(bytesReceived: 0, totalBytes: Int64(payload.count)))
            progress(DownloadProgress(bytesReceived: Int64(payload.count / 2), totalBytes: Int64(payload.count)))
            let file = directory.appendingPathComponent("\(fileStem).\(ext)")
            try payload.write(to: file)
            progress(DownloadProgress(bytesReceived: Int64(payload.count), totalBytes: Int64(payload.count)))
            return DownloadedFile(
                fileURL: file, mimeType: "audio/mpeg", byteCount: Int64(payload.count), resumed: false)
        case .fail(let error):
            throw error
        case .waitForCancel:
            started.fire()
            while !Task.isCancelled {
                await Task.yield()
            }
            throw CancellationError()
        }
    }
}

struct FakePodcasts: PodcastResolving {
    var episode = ResolvedPodcastEpisode(
        audioURL: "https://cdn.example.com/ep5.mp3", episodeTitle: "Ep. 5: A Synthetic Episode",
        showName: "The Synthetic Show", durationSeconds: 1800)
    var error: PodcastResolveError?

    func resolveApplePodcast(showID: String, episodeID: String?, link: URL) async throws -> ResolvedPodcastEpisode {
        if let error { throw error }
        return episode
    }

    func latestEpisode(inFeed feedURL: URL) async throws -> ResolvedPodcastEpisode {
        if let error { throw error }
        return episode
    }
}

struct FakeCaptions: YouTubeCaptionFetching {
    var result: Result<YouTubeCaptions, YouTubeCaptionError>

    static let sample = YouTubeCaptions(
        videoID: "AAAAAAAAAAA", title: "A Synthetic Talk", lengthSeconds: 12,
        track: YouTubeCaptionTrack(
            baseURL: URL(string: "https://www.youtube.com/api/timedtext?v=AAAAAAAAAAA&lang=en")!, languageCode: "en",
            name: "English", isGenerated: true),
        cues: [
            CaptionCue(startMs: 0, durationMs: 3_000, text: "hello and welcome to the synthetic talk"),
            CaptionCue(startMs: 2_000, durationMs: 2_000, text: "today we test captions"),
            CaptionCue(startMs: 6_000, durationMs: 1_000, text: "thanks"),
        ])

    func fetchCaptions(videoID: String, preferredLanguages: [String]) async throws -> YouTubeCaptions {
        try result.get()
    }
}

/// Collects progress events per id.
final class LinkProgressLog: Sendable {
    private let events = Mutex<[(UUID, JobProgress)]>([])

    var handler: @Sendable (UUID, JobProgress) -> Void {
        { [self] id, progress in events.withLock { $0.append((id, progress)) } }
    }

    func stages(for id: UUID) -> [PipelineStage] {
        events.withLock { $0.filter { $0.0 == id }.map(\.1.stage) }
    }

    func fractions(for id: UUID) -> [Double] {
        events.withLock { $0.filter { $0.0 == id }.map(\.1.fraction) }
    }
}

// MARK: - Tests

final class LinkIngestServiceTests: XCTestCase {
    private var root: URL!
    private var paths: AppPaths!
    private let store = FakeStore()
    private let log = LinkProgressLog()
    private let episodeLink = URL(string: "https://podcasts.apple.com/us/podcast/ep-5/id1000000001?i=1000000000002")!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LinkIngestServiceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        paths = AppPaths(root: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeService(
        downloader: any MediaDownloading, podcasts: FakePodcasts = FakePodcasts(),
        captions: FakeCaptions = FakeCaptions(result: .success(FakeCaptions.sample))
    ) -> LinkIngestService {
        LinkIngestService(
            paths: paths, store: store, http: IngestHTTPClient(configuration: .ephemeral), downloader: downloader,
            podcasts: podcasts, captions: captions, preferredLanguages: { ["en"] }, onProgress: log.handler)
    }

    func testPodcastEpisodeResolvesCreatesARowAndDownloadsIntoItsFolder() async throws {
        let downloader = FakeMediaDownloader(.succeed(ext: "mp3", payload: Data(repeating: 1, count: 1_000)))
        let service = makeService(downloader: downloader)
        let kind = LinkClassifier.classify(episodeLink.absoluteString)

        guard case .media(let source) = try await service.resolve(kind) else { return XCTFail("expected media") }
        XCTAssertEqual(source.sourceType, .podcast)
        XCTAssertEqual(source.downloadURL.absoluteString, "https://cdn.example.com/ep5.mp3")
        XCTAssertEqual(source.durationMs, 1_800_000)
        XCTAssertTrue(downloader.urls.isEmpty, "resolving never downloads")

        let id = try await service.createRow(for: source)
        let createdRow = await store.row(id)
        let created = try XCTUnwrap(createdRow)
        XCTAssertEqual(created.status, .processing)
        XCTAssertEqual(created.sourceType, .podcast)
        XCTAssertEqual(created.sourceURL, episodeLink.absoluteString)
        XCTAssertEqual(created.displayTitle, "Ep. 5: A Synthetic Episode")
        XCTAssertEqual(created.privacyClass, .personal, "links get the default class")
        XCTAssertNil(created.mediaRelativePath)

        let result = await service.download(id: id, from: source.downloadURL)
        XCTAssertEqual(result, .ready)
        let readyRow = await store.row(id)
        let ready = try XCTUnwrap(readyRow)
        XCTAssertEqual(ready.status, .processing, "still processing: the file pipeline runs next")
        XCTAssertEqual(ready.mediaRelativePath, "media/\(id.uuidString)/source.mp3")
        XCTAssertEqual(ready.fileSizeBytes, 1_000)
        XCTAssertEqual(ready.fileName, "Ep. 5 A Synthetic Episode.mp3")
        XCTAssertTrue(fileExists(paths.mediaDirectory(for: id).appendingPathComponent("source.mp3")))
        XCTAssertEqual(downloader.urls, [source.downloadURL])
        XCTAssertEqual(Set(log.stages(for: id)), [.downloading])
        XCTAssertEqual(log.fractions(for: id).last, 1)
    }

    func testDirectMediaKeepsTheLinkAsSourceTypeURL() async throws {
        let service = makeService(downloader: FakeMediaDownloader(.succeed(ext: "m4a", payload: Data([1]))))
        let link = URL(string: "https://cdn.example.com/talk.m4a")!
        guard case .media(let source) = try await service.resolve(.directMedia(link)) else {
            return XCTFail("expected media")
        }
        XCTAssertEqual(source, LinkMediaSource(downloadURL: link, link: link, sourceType: .url))
        let id = try await service.createRow(for: source)
        let row = await store.row(id)
        XCTAssertEqual(row?.fileName, "talk.m4a")
        XCTAssertEqual(row?.sourceURL, link.absoluteString)
    }

    /// Plan 022 review I1: Create makes a link's row with the class the person chose, from its first write.
    func testARowAndCaptionsCanBeCreatedClinicalFromTheStart() async throws {
        let service = makeService(downloader: FakeMediaDownloader(.fail(FakeError(message: "unused"))))
        let link = URL(string: "https://cdn.example.com/talk.m4a")!
        let id = try await service.createRow(
            for: LinkMediaSource(downloadURL: link, link: link, sourceType: .url), privacyClass: .clinical)
        let row = await store.row(id)
        XCTAssertEqual(row?.privacyClass, .clinical)
        XCTAssertEqual(row?.status, .processing)

        let video = URL(string: "https://youtu.be/AAAAAAAAAAA")!
        guard
            case .youtubeCaptions(let videoID, _) = try await service.resolve(
                LinkClassifier.classify(video.absoluteString))
        else {
            return XCTFail("expected captions")
        }
        let captions = try await service.importCaptions(videoID: videoID, link: video, privacyClass: .clinical)
        let captioned = await store.row(captions)
        XCTAssertEqual(captioned?.privacyClass, .clinical)
        XCTAssertEqual(captioned?.status, .completed)
    }

    func testUnsupportedLinkThrowsTheClassifierReasonWithoutARow() async {
        let service = makeService(downloader: FakeMediaDownloader(.fail(FakeError(message: "unused"))))
        do {
            _ = try await service.resolve(LinkClassifier.classify("https://x.com/a/status/1"))
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(LinkIngestService.readable(error).contains("can’t download from X"))
        }
        let rows = try? await store.fetchAll()
        XCTAssertEqual(rows?.count, 0)
    }

    func testFailedDownloadEndsFailedAndRetryDownloadsAgain() async throws {
        let downloader = FakeMediaDownloader(.fail(IngestNetworkError.offline))
        let service = makeService(downloader: downloader)
        let link = URL(string: "https://cdn.example.com/a.mp3")!
        let id = try await service.createRow(for: LinkMediaSource(downloadURL: link, link: link, sourceType: .url))

        let failed = await service.download(id: id, from: link)
        guard case .ended(let row) = failed else { return XCTFail("expected an end") }
        XCTAssertEqual(row?.status, .failed)
        XCTAssertEqual(row?.errorMessage, IngestNetworkError.offline.errorDescription)
        XCTAssertTrue(LinkIngestService.needsDownload(try XCTUnwrap(row)))

        downloader.setBehavior(.succeed(ext: "mp3", payload: Data([1, 2, 3])))
        let retried = await service.retryDownload(id: id)
        XCTAssertEqual(retried, .ready)
        let stored = await store.row(id)
        XCTAssertEqual(stored?.status, .processing)
        XCTAssertNil(stored?.errorMessage)
        XCTAssertEqual(stored?.mediaRelativePath, "media/\(id.uuidString)/source.mp3")
        XCTAssertEqual(downloader.urls, [link, link], "Retry re-resolves the stored link (a direct link is itself)")
    }

    func testRetryPrefersThePartialDownloadsRecordedURL() async throws {
        let downloader = FakeMediaDownloader(.fail(IngestNetworkError.timedOut))
        let service = makeService(downloader: downloader)
        let id = try await service.createRow(
            for: try LinkIngestService.source(for: FakePodcasts().episode, link: episodeLink))
        _ = await service.download(id: id, from: URL(string: "https://cdn.example.com/ep5.mp3")!)
        let recorded = URL(string: "https://cdn.example.com/redirected/ep5.mp3")!
        let info = paths.mediaDirectory(for: id).appendingPathComponent(MediaDownloader.partialInfoFileName)
        try JSONSerialization.data(withJSONObject: ["url": recorded.absoluteString]).write(to: info)

        downloader.setBehavior(.succeed(ext: "mp3", payload: Data([1])))
        _ = await service.retryDownload(id: id)
        XCTAssertEqual(downloader.urls.last, recorded)
    }

    func testCancelledDownloadEndsCancelled() async throws {
        let downloader = FakeMediaDownloader(.waitForCancel)
        let service = makeService(downloader: downloader)
        let link = URL(string: "https://cdn.example.com/a.mp3")!
        let id = try await service.createRow(for: LinkMediaSource(downloadURL: link, link: link, sourceType: .url))
        let task = Task { await service.download(id: id, from: link) }
        await downloader.started.wait()
        task.cancel()
        guard case .ended(let row) = await task.value else { return XCTFail("expected an end") }
        XCTAssertEqual(row?.status, .cancelled)
        XCTAssertNil(row?.errorMessage)
    }

    func testRowDeletedDuringTheDownloadIsNotRecreatedAndItsFolderGoes() async throws {
        let service = makeService(downloader: FakeMediaDownloader(.succeed(ext: "mp3", payload: Data([1]))))
        let link = URL(string: "https://cdn.example.com/a.mp3")!
        let id = try await service.createRow(for: LinkMediaSource(downloadURL: link, link: link, sourceType: .url))
        try await store.delete(id: id)
        let result = await service.download(id: id, from: link)
        XCTAssertEqual(result, .ended(nil))
        let gone = await store.row(id)
        XCTAssertNil(gone)
        XCTAssertFalse(fileExists(paths.mediaDirectory(for: id)))
    }

    func testDownloadThenTranscribeRunsTheTranscriptionOnlyWhenReady() async {
        let calls = Mutex(0)
        let transcribe: @Sendable () async -> Transcription? = {
            calls.withLock { $0 += 1 }
            return nil
        }
        _ = await LinkIngestService.downloadThenTranscribe(.ready, transcribe: transcribe)
        let ended = Transcription(fileName: "x", status: .failed)
        let result = await LinkIngestService.downloadThenTranscribe(.ended(ended), transcribe: transcribe)
        XCTAssertEqual(result, ended)
        XCTAssertEqual(calls.withLock { $0 }, 1)
    }

    func testYouTubeCaptionsBecomeACompletedURLRowWithTimedWords() async throws {
        let downloader = FakeMediaDownloader(.fail(FakeError(message: "never used")))
        let service = makeService(downloader: downloader)
        let link = URL(string: "https://youtu.be/AAAAAAAAAAA")!
        guard
            case .youtubeCaptions(let videoID, _) = try await service.resolve(
                LinkClassifier.classify(link.absoluteString))
        else {
            return XCTFail("expected captions")
        }
        let id = try await service.importCaptions(videoID: videoID, link: link)
        let stored = await store.row(id)
        let row = try XCTUnwrap(stored)
        XCTAssertEqual(row.status, .completed)
        XCTAssertEqual(row.sourceType, .url)
        XCTAssertEqual(row.sourceURL, link.absoluteString)
        XCTAssertEqual(row.displayTitle, "A Synthetic Talk")
        XCTAssertNil(row.mediaRelativePath, "captions only: no audio")
        XCTAssertEqual(row.engine, LinkIngestService.captionsEngineID)
        XCTAssertEqual(row.engineVariant, "asr")
        XCTAssertEqual(row.language, "en")
        XCTAssertEqual(row.durationMs, 12_000)
        XCTAssertEqual(
            row.rawTranscript, "hello and welcome to the synthetic talk today we test captions thanks")
        XCTAssertEqual(row.wordTimestamps?.count, 12)
        XCTAssertFalse(row.transcriptSegments?.isEmpty ?? true)
        XCTAssertTrue(downloader.urls.isEmpty, "no audio is downloaded")
    }

    func testVideoWithoutCaptionsCreatesNoRow() async throws {
        let service = makeService(
            downloader: FakeMediaDownloader(.fail(FakeError(message: "unused"))),
            captions: FakeCaptions(result: .failure(.noCaptions)))
        do {
            _ = try await service.importCaptions(
                videoID: "AAAAAAAAAAA", link: URL(string: "https://youtu.be/AAAAAAAAAAA")!)
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(LinkIngestService.readable(error).contains("share the file to Parakeet"))
        }
        let rows = try await store.fetchAll()
        XCTAssertTrue(rows.isEmpty)
    }

    func testCaptionWordsAreMonotonicAndStayInsideTheirCue() {
        let words = LinkIngestService.words(from: FakeCaptions.sample.cues)
        XCTAssertEqual(words.first?.startMs, 0)
        for (earlier, later) in zip(words, words.dropFirst()) {
            XCTAssertLessThanOrEqual(earlier.endMs, later.startMs + 1, "\(earlier.word) → \(later.word)")
            XCTAssertLessThan(later.startMs, later.endMs)
        }
        // The first cue overlaps the second (0–3 s vs 2 s): it is cut where the second begins.
        let firstCueEnd = words.prefix(7).map(\.endMs).max()
        XCTAssertEqual(firstCueEnd, 2_000)
        XCTAssertEqual(words.last?.word, "thanks")
        XCTAssertEqual(words.last?.startMs, 6_000)
        XCTAssertEqual(words.last?.endMs, 7_000)
        XCTAssertTrue(LinkIngestService.words(from: []).isEmpty)
    }

    func testDownloadShareKeepsSystemProgressMonotonic() {
        XCTAssertEqual(JobProgress(stage: .downloading, fraction: 1).overallFraction, JobProgress.downloadShare)
        XCTAssertEqual(JobProgress(stage: .transcribing, fraction: 0.5).overallFraction, 0.5)
        XCTAssertLessThanOrEqual(
            JobProgress(stage: .downloading, fraction: 1).overallFraction,
            JobProgress(stage: .transcribing, fraction: 0.15).overallFraction)
    }
}

/// `TranscriptionJobCenter.startTracked` (M5): tracked, cancellable work for an existing row.
@MainActor
final class TrackedJobTests: XCTestCase {
    func testStartTrackedRunsTheWorkAndCanBeCancelled() async {
        let center = TranscriptionJobCenter()
        let id = UUID()
        let entered = Signal()
        center.startTracked(id, title: "Episode") {
            entered.fire()
            while !Task.isCancelled {
                await Task.yield()
            }
            return Transcription(id: id, fileName: "x", status: .cancelled)
        }
        await entered.wait()
        XCTAssertTrue(center.isRunning(id))
        center.update(id, JobProgress(stage: .downloading, fraction: 0.5))
        XCTAssertEqual(center.progress[id]?.stage, .downloading)
        center.cancel(id)
        await center.waitUntilIdle()
        XCTAssertFalse(center.isRunning(id))
        XCTAssertNil(center.progress[id])
    }
}
