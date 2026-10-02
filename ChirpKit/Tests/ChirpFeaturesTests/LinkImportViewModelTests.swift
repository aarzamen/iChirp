import ChirpCore
import ChirpIngest
import Foundation
import XCTest

@testable import ChirpFeatures

/// The Paste a link sheet's logic: local classification, one explicit network action, errors without rows.
@MainActor
final class LinkImportViewModelTests: XCTestCase {
    private var root: URL!
    private let store = FakeStore()
    private var started: [(UUID, LinkMediaSource)] = []
    /// Called after each started job is recorded.
    private var onStarted: (() -> Void)?

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LinkImportViewModelTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        started = []
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeModel(
        podcasts: FakePodcasts = FakePodcasts(),
        captions: FakeCaptions = FakeCaptions(result: .success(FakeCaptions.sample))
    ) -> LinkImportViewModel {
        let service = LinkIngestService(
            paths: AppPaths(root: root), store: store, http: IngestHTTPClient(configuration: .ephemeral),
            downloader: FakeMediaDownloader(.fail(FakeError(message: "unused"))), podcasts: podcasts,
            captions: captions, preferredLanguages: { ["en"] }, onProgress: { _, _ in })
        return LinkImportViewModel(service: service) { [weak self] id, source in
            self?.started.append((id, source))
            self?.onStarted?()
        }
    }

    func testTypingClassifiesLocallyAndGatesTranscribe() {
        let model = makeModel()
        XCTAssertFalse(model.canTranscribe)
        model.text = "https://x.com/a/status/1"
        XCTAssertEqual(model.kind, .unsupported(.platform(name: "X")))
        XCTAssertFalse(model.canTranscribe)
        model.text = "https://podcasts.apple.com/us/podcast/ep/id1000000001?i=1000000000002"
        XCTAssertEqual(model.kind.title, "Apple Podcasts episode")
        XCTAssertTrue(model.canTranscribe)
        XCTAssertEqual(model.phase, .editing)
    }

    func testPodcastCreatesARowAndStartsItsJob() async throws {
        let model = makeModel()
        model.text = "https://podcasts.apple.com/us/podcast/ep/id1000000001?i=1000000000002"
        model.transcribe()
        XCTAssertTrue(model.isWorking)
        XCTAssertFalse(model.canTranscribe, "one tap, one job")
        await model.waitUntilSettled()

        let id = try XCTUnwrap(model.startedID)
        XCTAssertEqual(started.map(\.0), [id])
        XCTAssertEqual(started.first?.1.downloadURL.absoluteString, "https://cdn.example.com/ep5.mp3")
        let row = await store.row(id)
        XCTAssertEqual(row?.status, .processing)
        XCTAssertEqual(row?.sourceType, .podcast)
    }

    func testYouTubeFinishesInTheSheetWithoutAJob() async throws {
        let model = makeModel()
        model.text = "https://www.youtube.com/watch?v=AAAAAAAAAAA"
        model.transcribe()
        await model.waitUntilSettled()
        let id = try XCTUnwrap(model.startedID)
        XCTAssertTrue(started.isEmpty, "captions need no download job")
        let row = await store.row(id)
        XCTAssertEqual(row?.status, .completed)
    }

    func testFailureStaysInTheSheetAndEditingClearsIt() async throws {
        let model = makeModel(podcasts: FakePodcasts(error: .episodeNotFound))
        model.text = "https://podcasts.apple.com/us/podcast/ep/id1000000001?i=1000000000002"
        model.transcribe()
        await model.waitUntilSettled()
        XCTAssertEqual(model.phase, .failed(PodcastResolveError.episodeNotFound.errorDescription!))
        XCTAssertTrue(model.canTranscribe, "Try again is allowed")
        let rows = try await store.fetchAll()
        XCTAssertTrue(rows.isEmpty, "no half-created row")
        model.text += " "
        XCTAssertEqual(model.phase, .editing)
    }

    // MARK: - Review R4-15: once the row exists, its job always starts

    private let podcastLink = "https://podcasts.apple.com/us/podcast/ep/id1000000001?i=1000000000002"

    /// Reset while the row is being written: the row's job still starts (a row never waits in "Downloading…" with no
    /// job), and the cleared sheet stays cleared.
    func testResetWhileTheRowIsBeingWrittenStillStartsItsJob() async throws {
        let model = makeModel()
        let jobStarted = expectation(description: "the row's job started")
        onStarted = { jobStarted.fulfill() }
        let hold = await store.holdNext([.insert])
        model.text = podcastLink
        model.transcribe()
        await hold.entered.wait()

        model.reset()
        hold.release.fire()
        await fulfillment(of: [jobStarted], timeout: 5)

        XCTAssertEqual(started.count, 1, "the row's download and transcription run")
        let row = await store.row(try XCTUnwrap(started.first?.0))
        XCTAssertEqual(row?.status, .processing)
        XCTAssertEqual(model.phase, .editing, "the cleared sheet is not taken over by the earlier link")
        XCTAssertNil(model.startedID)
        XCTAssertEqual(model.text, "")
    }

    /// The sheet closes (its model goes, cancelling the lookup) while the row is being written: the job still starts.
    func testClosingTheSheetWhileTheRowIsBeingWrittenStillStartsItsJob() async throws {
        var model: LinkImportViewModel? = makeModel()
        let jobStarted = expectation(description: "the row's job started")
        onStarted = { jobStarted.fulfill() }
        let hold = await store.holdNext([.insert])
        model?.text = podcastLink
        model?.transcribe()
        await hold.entered.wait()

        weak var released = model
        model = nil
        XCTAssertNil(released, "the sheet's model is gone")
        hold.release.fire()
        await fulfillment(of: [jobStarted], timeout: 5)

        XCTAssertEqual(started.count, 1)
        let row = await store.row(try XCTUnwrap(started.first?.0))
        XCTAssertEqual(row?.status, .processing)
    }

    /// Cancel during the lookup, before any row: nothing is created and the sheet is ready again.
    func testCancelBeforeTheRowExistsCreatesNothing() async throws {
        let model = makeModel()
        model.text = podcastLink
        model.transcribe()
        model.cancel()
        await model.waitUntilSettled()

        XCTAssertEqual(model.phase, .editing)
        XCTAssertTrue(model.canTranscribe, "Transcribe is offered again")
        XCTAssertTrue(started.isEmpty)
        let rows = try await store.fetchAll()
        XCTAssertTrue(rows.isEmpty, "the cancelled lookup created no row")
    }

    func testResetClearsForAnotherLink() async {
        let model = makeModel()
        model.text = "https://www.youtube.com/watch?v=AAAAAAAAAAA"
        model.transcribe()
        await model.waitUntilSettled()
        model.reset()
        XCTAssertEqual(model.text, "")
        XCTAssertEqual(model.phase, .editing)
        XCTAssertEqual(model.kind, .unsupported(.empty))
    }
}
