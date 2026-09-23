import ChirpCore
import ChirpIngest
import Foundation
import Synchronization
import XCTest

@testable import ChirpFeatures

// MARK: - Fakes

/// A Mac companion that writes `payload` as `<stem>.m4a`, fails, or waits until cancelled. Records every link.
final class FakeCompanionAudio: CompanionAudioFetching {
    enum Behavior: Sendable {
        case succeed(title: String?, durationMs: Int?, payload: Data)
        case fail(any Error & Sendable)
        case waitForCancel
    }

    private let state: Mutex<(behavior: Behavior, links: [URL], endpoint: CompanionEndpoint)>
    let started = Signal()

    init(_ behavior: Behavior, endpoint: CompanionEndpoint = CompanionEndpoint(host: "studio.local")) {
        state = Mutex((behavior, [], endpoint))
    }

    var links: [URL] { state.withLock { $0.links } }
    var endpoint: CompanionEndpoint { state.withLock { $0.endpoint } }

    func setBehavior(_ behavior: Behavior) {
        state.withLock { $0.behavior = behavior }
    }

    /// The owner pointed Settings → Mac companion at another Mac.
    func setEndpoint(_ endpoint: CompanionEndpoint) {
        state.withLock { $0.endpoint = endpoint }
    }

    func youtubeAudio(
        url: URL, into directory: URL, fileStem: String, progress: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws -> CompanionAudio {
        let behavior = state.withLock { state -> Behavior in
            state.links.append(url)
            return state.behavior
        }
        switch behavior {
        case .succeed(let title, let durationMs, let payload):
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            progress(DownloadProgress(bytesReceived: Int64(payload.count / 2), totalBytes: Int64(payload.count)))
            let file = directory.appendingPathComponent("\(fileStem).m4a")
            try payload.write(to: file)
            return CompanionAudio(
                fileURL: file, title: title, durationMs: durationMs, byteCount: Int64(payload.count))
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

/// A downloader whose server never says the size (no Content-Length).
final class UnknownSizeDownloader: MediaDownloading {
    func download(
        from url: URL, into directory: URL, fileStem: String,
        progress: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws -> DownloadedFile {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        progress(DownloadProgress(bytesReceived: 0, totalBytes: nil))
        progress(DownloadProgress(bytesReceived: 300_000, totalBytes: nil))
        let file = directory.appendingPathComponent("\(fileStem).mp3")
        try Data([1, 2, 3]).write(to: file)
        return DownloadedFile(fileURL: file, mimeType: "audio/mpeg", byteCount: 3, resumed: false)
    }
}

/// Collects full progress values per id.
final class JobProgressLog: Sendable {
    private let events = Mutex<[(UUID, JobProgress)]>([])

    var handler: @Sendable (UUID, JobProgress) -> Void {
        { [self] id, progress in events.withLock { $0.append((id, progress)) } }
    }

    func progress(for id: UUID) -> [JobProgress] {
        events.withLock { $0.filter { $0.0 == id }.map(\.1) }
    }
}

// MARK: - LinkIngestService: YouTube audio through the companion, and unknown download sizes

final class CompanionIngestTests: XCTestCase {
    private var root: URL!
    private var paths: AppPaths!
    private let store = FakeStore()
    private let log = JobProgressLog()
    private let link = URL(string: "https://www.youtube.com/watch?v=AAAAAAAAAAA")!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CompanionIngestTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        paths = AppPaths(root: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeService(
        companion: FakeCompanionAudio?,
        downloader: any MediaDownloading = FakeMediaDownloader(.fail(FakeError(message: "unused")))
    ) -> LinkIngestService {
        LinkIngestService(
            paths: paths, store: store, http: IngestHTTPClient(configuration: .ephemeral), downloader: downloader,
            podcasts: FakePodcasts(), captions: FakeCaptions(result: .failure(.noCaptions)),
            companion: { companion }, preferredLanguages: { ["en"] }, onProgress: log.handler)
    }

    func testCompanionAudioBecomesTheRowsMediaWithTheVideosTitleAndDuration() async throws {
        let companion = FakeCompanionAudio(
            .succeed(title: "A Synthetic Talk: Part 1/2", durationMs: 61_500, payload: Data(repeating: 1, count: 500)))
        let service = makeService(companion: companion)
        let source = LinkMediaSource.companionYouTube(link)
        XCTAssertEqual(source.transport, .companion)

        let id = try await service.createRow(for: source)
        let createdRow = await store.row(id)
        let created = try XCTUnwrap(createdRow)
        XCTAssertEqual(created.fileName, "YouTube video")
        XCTAssertEqual(created.sourceType, .url)
        XCTAssertEqual(created.sourceURL, link.absoluteString)
        XCTAssertEqual(created.status, .processing)
        XCTAssertEqual(log.progress(for: id).first, .indeterminate(.downloading), "no made-up 0% before the answer")

        let result = await service.download(id: id, source: source)
        XCTAssertEqual(result, .ready)
        XCTAssertEqual(companion.links, [link], "only the link goes to the Mac")
        let readyRow = await store.row(id)
        let ready = try XCTUnwrap(readyRow)
        XCTAssertEqual(ready.status, .processing, "the file pipeline runs next, on this iPhone")
        XCTAssertEqual(ready.mediaRelativePath, "media/\(id.uuidString)/source.m4a")
        XCTAssertEqual(ready.fileSizeBytes, 500)
        XCTAssertEqual(ready.sourceTitle, "A Synthetic Talk: Part 1/2")
        XCTAssertEqual(ready.fileName, "A Synthetic Talk Part 1 2.m4a")
        XCTAssertEqual(ready.durationMs, 61_500)
        XCTAssertFalse(LinkIngestService.needsDownload(ready))
        XCTAssertEqual(log.progress(for: id).last?.fraction, 0.5)
    }

    func testCompanionFailureEndsFailedWithItsSentenceAndRetryAsksTheMacAgain() async throws {
        let companion = FakeCompanionAudio(
            .fail(CompanionError.server(status: 422, code: "video_unavailable", message: "This video is unavailable.")))
        let service = makeService(companion: companion)
        let id = try await service.createRow(for: .companionYouTube(link))

        let failed = await service.download(id: id, source: .companionYouTube(link))
        guard case .ended(let row) = failed else { return XCTFail("expected an end") }
        XCTAssertEqual(row?.status, .failed)
        XCTAssertEqual(row?.errorMessage, "This video is unavailable.")
        XCTAssertTrue(LinkIngestService.needsDownload(try XCTUnwrap(row)))

        companion.setBehavior(.succeed(title: nil, durationMs: nil, payload: Data([1, 2])))
        let retried = await service.retryDownload(id: id)
        XCTAssertEqual(retried, .ready)
        XCTAssertEqual(companion.links, [link, link])
        let stored = await store.row(id)
        XCTAssertEqual(stored?.mediaRelativePath, "media/\(id.uuidString)/source.m4a")
        XCTAssertEqual(stored?.fileName, "YouTube video.m4a")
    }

    /// Review L1 I1: the phone sends only `https://www.youtube.com/watch?v=<id>`, rebuilt from the validated id, for
    /// the first download and for Retry; share parameters never leave the phone. The row keeps the pasted link.
    func testOnlyTheCanonicalWatchLinkGoesToTheMacForAYouTubeMusicLink() async throws {
        let pasted = URL(string: "https://music.youtube.com/watch?v=BBBBBBBBBBB&si=SyntheticShare1&list=RDSYNTH&t=42")!
        let canonical = URL(string: "https://www.youtube.com/watch?v=BBBBBBBBBBB")!
        let companion = FakeCompanionAudio(.fail(CompanionError.server(status: 502, code: nil, message: "Offline.")))
        let service = makeService(companion: companion)
        let source = LinkMediaSource.companionYouTube(pasted)
        XCTAssertEqual(source.downloadURL, canonical)
        let id = try await service.createRow(for: source)
        let createdRow = await store.row(id)
        XCTAssertEqual(createdRow?.sourceURL, pasted.absoluteString, "the row keeps the link as pasted, on the phone")

        _ = await service.download(id: id, source: source)
        companion.setBehavior(.succeed(title: nil, durationMs: nil, payload: Data([1, 2])))
        let retried = await service.retryDownload(id: id)
        XCTAssertEqual(retried, .ready)
        XCTAssertEqual(companion.links, [canonical, canonical])
        for sent in companion.links {
            XCTAssertFalse(sent.absoluteString.contains("si="))
            XCTAssertFalse(sent.absoluteString.contains("list="))
        }
    }

    func testOtherYouTubeLinkFormsAreRebuiltToo() {
        for raw in [
            "https://youtu.be/CCCCCCCCCCC?si=SyntheticShare2", "https://www.youtube-nocookie.com/embed/CCCCCCCCCCC",
            "https://www.youtube.com/shorts/CCCCCCCCCCC/extra", "https://m.youtube.com/WATCH?v=CCCCCCCCCCC&v=DDDDDDDDDDD",
        ] {
            XCTAssertEqual(
                LinkMediaSource.companionYouTube(URL(string: raw)!).downloadURL.absoluteString,
                "https://www.youtube.com/watch?v=CCCCCCCCCCC", raw)
        }
    }

    /// Review L1 M2: a Retry goes to the companion without a new question only while it is the Mac the link was
    /// confirmed for; after the owner points Settings at another Mac, Retry asks first and the service refuses until
    /// then.
    func testRetryToAnotherMacNeedsANewConfirmation() async throws {
        let companion = FakeCompanionAudio(.fail(CompanionError.server(status: 502, code: nil, message: "Offline.")))
        let service = makeService(companion: companion)
        let source = LinkMediaSource.companionYouTube(link)
        let id = try await service.createRow(for: source)
        _ = await service.download(id: id, source: source)
        let sameMac = await service.companionRetryConfirmationHost(id: id)
        XCTAssertNil(sameMac, "the same Mac: no new question")

        companion.setEndpoint(CompanionEndpoint(host: "other-mac.local"))
        let asked = await service.companionRetryConfirmationHost(id: id)
        XCTAssertEqual(asked, "other-mac.local")
        companion.setBehavior(.succeed(title: nil, durationMs: nil, payload: Data([1])))
        let refused = await service.retryDownload(id: id)
        guard case .ended(let row) = refused else { return XCTFail("the service is the gate") }
        XCTAssertEqual(row?.status, .failed)
        XCTAssertEqual(companion.links.count, 1, "the link did not go to the new Mac")

        await service.confirmCompanionRetry(id: id)
        let afterConfirm = await service.companionRetryConfirmationHost(id: id)
        XCTAssertNil(afterConfirm)
        let retried = await service.retryDownload(id: id)
        XCTAssertEqual(retried, .ready)
        XCTAssertEqual(companion.links.count, 2)
    }

    func testRetryOfALinkNotConfirmedInThisLaunchAsksFirst() async throws {
        // A row from an earlier launch: the confirmation lived in memory, so Retry asks again.
        let companion = FakeCompanionAudio(.succeed(title: nil, durationMs: nil, payload: Data([1])))
        let service = makeService(companion: companion)
        let id = try await service.createRow(for: .companionYouTube(link))
        _ = try await store.transitionStatus(id: id, from: [.processing], to: .failed, errorMessage: "Offline.")
        let host = await service.companionRetryConfirmationHost(id: id)
        XCTAssertEqual(host, "studio.local")
        await service.confirmCompanionRetry(id: id)
        let retried = await service.retryDownload(id: id)
        XCTAssertEqual(retried, .ready)
    }

    func testWithoutACompanionTheDownloadEndsWithTheSetupSentence() async throws {
        let service = makeService(companion: nil)
        XCTAssertFalse(service.isCompanionConfigured())
        let id = try await service.createRow(for: .companionYouTube(link))
        let result = await service.download(id: id, source: .companionYouTube(link))
        guard case .ended(let row) = result else { return XCTFail("expected an end") }
        XCTAssertEqual(row?.status, .failed)
        XCTAssertEqual(row?.errorMessage, LinkIngestError.companionNotConfigured.errorDescription)
        XCTAssertTrue(row?.errorMessage?.contains("Settings → Mac companion") == true)
    }

    func testCancelledCompanionDownloadEndsCancelled() async throws {
        let companion = FakeCompanionAudio(.waitForCancel)
        let service = makeService(companion: companion)
        let source = LinkMediaSource.companionYouTube(link)
        let id = try await service.createRow(for: source)
        let task = Task { await service.download(id: id, source: source) }
        await companion.started.wait()
        task.cancel()
        guard case .ended(let row) = await task.value else { return XCTFail("expected an end") }
        XCTAssertEqual(row?.status, .cancelled)
    }

    func testDirectLinksStillDownloadHere() async throws {
        let companion = FakeCompanionAudio(.fail(FakeError(message: "never used")))
        let downloader = FakeMediaDownloader(.succeed(ext: "mp3", payload: Data([1])))
        let service = makeService(companion: companion, downloader: downloader)
        let direct = URL(string: "https://cdn.example.com/a.mp3")!
        let source = LinkMediaSource(downloadURL: direct, link: direct, sourceType: .url)
        XCTAssertEqual(source.transport, .direct)
        let id = try await service.createRow(for: source)
        let result = await service.download(id: id, source: source)
        XCTAssertEqual(result, .ready)
        XCTAssertEqual(downloader.urls, [direct])
        XCTAssertTrue(companion.links.isEmpty)
    }

    // MARK: - Plan 014 open item: unknown download sizes

    func testUnknownSizeDownloadIsIndeterminateAndNeverZeroPercent() async throws {
        let service = makeService(companion: nil, downloader: UnknownSizeDownloader())
        let direct = URL(string: "https://cdn.example.com/live.mp3")!
        let id = try await service.createRow(for: LinkMediaSource(downloadURL: direct, link: direct, sourceType: .url))
        let result = await service.download(id: id, from: direct)
        XCTAssertEqual(result, .ready)
        let events = log.progress(for: id)
        XCTAssertEqual(events.count, 3)
        XCTAssertTrue(events.allSatisfy(\.isIndeterminate), "unknown size: Downloading…, never a percentage")
        XCTAssertTrue(events.allSatisfy { $0.determinateFraction == nil })
    }

    func testIndeterminateProgressHasNoFraction() {
        let progress = JobProgress.indeterminate(.downloading)
        XCTAssertTrue(progress.isIndeterminate)
        XCTAssertEqual(progress.fraction, 0)
        XCTAssertNil(progress.determinateFraction)
        XCTAssertEqual(progress.overallFraction, 0)
        XCTAssertEqual(JobProgress(stage: .downloading, fraction: 0.4).determinateFraction, 0.4)
        XCTAssertEqual(
            LinkIngestService.jobProgress(DownloadProgress(bytesReceived: 5, totalBytes: 10)),
            JobProgress(stage: .downloading, fraction: 0.5))
        XCTAssertEqual(
            LinkIngestService.jobProgress(DownloadProgress(bytesReceived: 5, totalBytes: nil)),
            .indeterminate(.downloading))
    }
}

// MARK: - The Paste a link sheet's companion offer

@MainActor
final class LinkImportCompanionOfferTests: XCTestCase {
    private var root: URL!
    private let store = FakeStore()
    private var started: [(UUID, LinkMediaSource)] = []
    private let youtube = "https://www.youtube.com/watch?v=AAAAAAAAAAA"

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LinkImportCompanionOfferTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        started = []
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeModel(captionsError: YouTubeCaptionError, companion: FakeCompanionAudio?) -> LinkImportViewModel {
        let service = LinkIngestService(
            paths: AppPaths(root: root), store: store, http: IngestHTTPClient(configuration: .ephemeral),
            downloader: FakeMediaDownloader(.fail(FakeError(message: "unused"))), podcasts: FakePodcasts(),
            captions: FakeCaptions(result: .failure(captionsError)), companion: { companion },
            preferredLanguages: { ["en"] }, onProgress: { _, _ in })
        return LinkImportViewModel(service: service) { [weak self] id, source in
            self?.started.append((id, source))
        }
    }

    func testNoCaptionsWithACompanionOffersMacAudioAfterOneConfirmation() async throws {
        let model = makeModel(captionsError: .noCaptions, companion: FakeCompanionAudio(.waitForCancel))
        model.text = youtube
        model.transcribe()
        await model.waitUntilSettled()
        XCTAssertEqual(model.phase, .companionOffer("This video has no captions."))
        XCTAssertEqual(model.companionLink?.absoluteString, youtube)
        XCTAssertFalse(model.canTranscribe)
        XCTAssertTrue(model.needsCompanionConfirmation)
        let rowsBefore = try await store.fetchAll()
        XCTAssertTrue(rowsBefore.isEmpty, "nothing is created before the person agrees")

        model.getAudioFromMac()
        XCTAssertEqual(model.phase, .companionOffer("This video has no captions."), "unconfirmed: nothing happens")
        XCTAssertTrue(started.isEmpty)

        model.confirmCompanion()
        XCTAssertFalse(model.needsCompanionConfirmation)
        model.getAudioFromMac()
        await model.waitUntilSettled()
        let id = try XCTUnwrap(model.startedID)
        XCTAssertEqual(started.map(\.0), [id])
        XCTAssertEqual(started.first?.1, .companionYouTube(URL(string: youtube)!))
        let row = await store.row(id)
        XCTAssertEqual(row?.status, .processing)
        XCTAssertEqual(row?.fileName, "YouTube video")

        // The same link again in this sheet: offered again, but not asked again.
        model.reset()
        model.text = youtube
        model.transcribe()
        await model.waitUntilSettled()
        XCTAssertEqual(model.phase, .companionOffer("This video has no captions."))
        XCTAssertFalse(model.needsCompanionConfirmation, "confirmed once per link")
    }

    func testCaptionsYouTubeRefusedAreAlsoOffered() async {
        let model = makeModel(captionsError: .tokenRequired, companion: FakeCompanionAudio(.waitForCancel))
        model.text = youtube
        model.transcribe()
        await model.waitUntilSettled()
        XCTAssertEqual(model.phase, .companionOffer("YouTube wouldn’t give Parakeet this video’s captions."))
    }

    func testNoCaptionsWithoutACompanionSaysHowToSetItUp() async throws {
        let model = makeModel(captionsError: .noCaptions, companion: nil)
        model.text = youtube
        model.transcribe()
        await model.waitUntilSettled()
        guard case .failed(let message) = model.phase else { return XCTFail("expected a failure") }
        XCTAssertTrue(message.hasPrefix("This video has no captions."))
        XCTAssertTrue(message.contains("Settings → Mac companion"))
        XCTAssertNil(model.companionLink)
        let rows = try await store.fetchAll()
        XCTAssertTrue(rows.isEmpty)
    }

    func testUnavailableVideoIsNotOffered() async {
        let model = makeModel(captionsError: .videoUnavailable, companion: FakeCompanionAudio(.waitForCancel))
        model.text = youtube
        model.transcribe()
        await model.waitUntilSettled()
        XCTAssertEqual(model.phase, .failed(YouTubeCaptionError.videoUnavailable.errorDescription!))
    }

    func testEditingTheLinkWithdrawsTheOffer() async {
        let model = makeModel(captionsError: .noCaptions, companion: FakeCompanionAudio(.waitForCancel))
        model.text = youtube
        model.transcribe()
        await model.waitUntilSettled()
        model.text = "https://www.youtube.com/watch?v=BBBBBBBBBBB"
        XCTAssertEqual(model.phase, .editing)
        XCTAssertNil(model.companionLink)
        XCTAssertTrue(model.canTranscribe)
    }

    func testCaptionsFirstIsUnchanged() async throws {
        let service = LinkIngestService(
            paths: AppPaths(root: root), store: store, http: IngestHTTPClient(configuration: .ephemeral),
            downloader: FakeMediaDownloader(.fail(FakeError(message: "unused"))), podcasts: FakePodcasts(),
            captions: FakeCaptions(result: .success(FakeCaptions.sample)),
            companion: { FakeCompanionAudio(.fail(FakeError(message: "never used"))) },
            preferredLanguages: { ["en"] }, onProgress: { _, _ in })
        let model = LinkImportViewModel(service: service) { [weak self] id, source in
            self?.started.append((id, source))
        }
        model.text = youtube
        model.transcribe()
        await model.waitUntilSettled()
        let id = try XCTUnwrap(model.startedID)
        XCTAssertTrue(started.isEmpty, "captions exist: no companion, no job")
        let row = await store.row(id)
        XCTAssertEqual(row?.status, .completed)
        XCTAssertEqual(row?.engine, LinkIngestService.captionsEngineID)
    }
}
