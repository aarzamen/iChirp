import ChirpCore
import ChirpIngest
import Foundation
import XCTest

@testable import ChirpFeatures

/// Plan 029: Paste a link takes a shared link. An idle, empty sheet starts it at once; a sheet holding typing or a run
/// keeps it and the shared link waits ("Shared link · Start") until the sheet is idle again or the person taps Start.
@MainActor
final class LinkSheetHostTests: XCTestCase {
    private var root: URL!
    private let store = FakeStore()
    private let linkA = URL(string: "https://www.youtube.com/watch?v=AAAAAAAAAAA")!
    private let linkB = URL(string: "https://youtu.be/BBBBBBBBBBB")!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LinkSheetHostTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeHost() -> LinkSheetHost {
        let root = self.root!
        let store = self.store
        return LinkSheetHost {
            let service = LinkIngestService(
                paths: AppPaths(root: root), store: store, http: IngestHTTPClient(configuration: .ephemeral),
                downloader: FakeMediaDownloader(.fail(FakeError(message: "unused"))), podcasts: FakePodcasts(),
                captions: FakeCaptions(result: .success(FakeCaptions.sample)), preferredLanguages: { ["en"] },
                onProgress: { _, _ in })
            return LinkImportViewModel(service: service) { _, _ in }
        }
    }

    func testDeliverToIdleSheetStartsAtOnce() {
        let host = makeHost()
        host.deliver(linkA, start: .autoStart)
        XCTAssertTrue(host.isPresented)
        XCTAssertNil(host.waiting)
        XCTAssertTrue(host.model.isWorking)
    }

    func testDeliverPrefillWaitsForTranscribe() {
        let host = makeHost()
        host.deliver(linkA, start: .prefill)
        XCTAssertEqual(host.model.text, linkA.absoluteString)
        XCTAssertEqual(host.model.phase, .editing)
    }

    func testBusySheetKeepsStateAndQueuesSharedLink() async throws {
        let host = makeHost()
        host.isPresented = true
        host.model.text = linkA.absoluteString
        host.model.transcribe()
        host.deliver(linkB, start: .autoStart)
        XCTAssertEqual(host.waiting?.link, linkB)
        XCTAssertEqual(host.model.text, linkA.absoluteString, "the running link is not replaced")

        await host.model.waitUntilSettled()
        XCTAssertNotNil(host.model.startedID)
        host.modelDidChange()
        XCTAssertNil(host.waiting)
        XCTAssertEqual(host.model.text, linkB.absoluteString)
        await host.model.waitUntilSettled()
        let rows = try await store.fetchAll()
        XCTAssertEqual(rows.count, 2, "each link once")
    }

    func testTypedTextIsNotReplaced() {
        let host = makeHost()
        host.isPresented = true
        host.model.text = "my podcast"
        host.deliver(linkB, start: .autoStart)
        host.modelDidChange()
        XCTAssertEqual(host.model.text, "my podcast")
        XCTAssertEqual(host.waiting?.link, linkB)
    }

    func testTapStartReplacesOnPurpose() {
        let host = makeHost()
        host.isPresented = true
        host.model.text = "my podcast"
        host.deliver(linkB, start: .prefill)
        host.startWaiting()
        XCTAssertNil(host.waiting)
        XCTAssertEqual(host.model.text, linkB.absoluteString)
        XCTAssertTrue(host.model.isWorking, "the tap is the person's Transcribe")
    }

    func testDismissGivesTheNextOpenAFreshSheet() {
        let host = makeHost()
        host.isPresented = true
        host.model.text = "my podcast"
        host.deliver(linkB, start: .prefill)
        host.isPresented = false
        host.sheetDidDismiss()
        XCTAssertNil(host.waiting)
        XCTAssertTrue(host.model.isIdleAndEmpty)
    }
}
