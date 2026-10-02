import ChirpCore
import CryptoKit
import Foundation
import Synchronization
import XCTest

@testable import ChirpEngineNeedle

/// Review R3-5 and R3-6: the Needle download gets the fixes its llama.cpp sibling received (review minors 3 and 5),
/// mirrored from `LlamaCppModelAssetsTests`: cancelling the caller cancels the fetch, progress is throttled and never
/// goes backwards, and a cancellation or a Delete during a download is not a failure. No network, no model.
final class NeedleModelAssetsTests: XCTestCase {
    private var root: URL!
    private let bytes = Data("synthetic needle weights".utf8)

    override func setUp() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("NeedleAssetsTests-\(UUID())")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    private func pin(for payload: Data) -> NeedleModelAssets.Pin {
        let hash = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        return NeedleModelAssets.Pin(
            fileName: "needle3.cact", remoteURL: URL(string: "https://example.invalid/needle3.cact")!, sha256: hash,
            byteCount: Int64(payload.count), revision: "test")
    }

    private func waitUntil(_ condition: @Sendable () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            await Task.yield()
        }
        return await condition()
    }

    func testADownloadedModelIsVerifiedKeptAndExcludedFromBackup() async throws {
        let assets = NeedleModelAssets(modelsDirectory: root, pin: pin(for: bytes), fetcher: FakeFetcher(bytes: bytes))
        try await assets.downloadModel { _ in }
        let ready = await assets.isReady
        XCTAssertTrue(ready)
        let excluded = try assets.directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup
        XCTAssertEqual(excluded, true, "parity with every other model download (review R3-4)")
    }

    /// The continued-processing expiration cancels the task that called `downloadModel`; that must stop the fetch,
    /// and a cancelled download reads as not downloaded, not as a failure.
    func testCancellingTheCallerStopsTheDownloadAndIsNotAFailure() async throws {
        let fetcher = HangingNeedleFetcher()
        let assets = NeedleModelAssets(modelsDirectory: root, pin: pin(for: bytes), fetcher: fetcher)
        let caller = Task { try await assets.downloadModel { _ in } }
        let started = await waitUntil { fetcher.started }
        XCTAssertTrue(started)
        caller.cancel()
        let stopped = await waitUntil { fetcher.sawCancellation }
        XCTAssertTrue(stopped, "the fetch inside the unstructured task was cancelled")
        do {
            try await caller.value
            XCTFail("a cancelled download does not succeed")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        let status = await assets.status()
        XCTAssertEqual(status, .notDownloaded, "a cancellation is not a failure")
    }

    func testDeleteDuringADownloadStopsItAndReadsNotDownloaded() async throws {
        let fetcher = HangingNeedleFetcher()
        let assets = NeedleModelAssets(modelsDirectory: root, pin: pin(for: bytes), fetcher: fetcher)
        let caller = Task { try await assets.downloadModel { _ in } }
        let started = await waitUntil { fetcher.started }
        XCTAssertTrue(started)
        try await assets.deleteModel()
        _ = await caller.result
        XCTAssertTrue(fetcher.sawCancellation)
        let status = await assets.status()
        XCTAssertEqual(status, .notDownloaded, "Delete mid-download is not a failure")
        XCTAssertFalse(FileManager.default.fileExists(atPath: assets.directory.path))
    }

    /// Tens of thousands of URLSession callbacks become at most ~200 forward steps.
    func testProgressIsThrottledAndNeverGoesBackwards() async throws {
        let assets = NeedleModelAssets(
            modelsDirectory: root, pin: pin(for: bytes), fetcher: ChattyNeedleFetcher(bytes: bytes, steps: 20_000))
        let seen = Mutex<[Double]>([])
        try await assets.downloadModel { fraction in seen.withLock { $0.append(fraction) } }
        let reported = seen.withLock { $0 }
        XCTAssertLessThanOrEqual(reported.count, 202)
        XCTAssertEqual(reported, reported.sorted(), "never backwards")
        XCTAssertEqual(reported.last, 1)
        let ready = await assets.isReady
        XCTAssertTrue(ready)
    }

    /// The Tasks that carry progress to the status can arrive out of order; the status keeps the highest.
    func testTheStatusNeverGoesBackwardsWhenProgressArrivesOutOfOrder() async throws {
        let fetcher = HangingNeedleFetcher()
        let assets = NeedleModelAssets(modelsDirectory: root, pin: pin(for: bytes), fetcher: fetcher)
        let caller = Task { try await assets.downloadModel { _ in } }
        let started = await waitUntil { fetcher.started }
        XCTAssertTrue(started)
        await assets.record(fraction: 0.62)
        await assets.record(fraction: 0.58)
        let status = await assets.status()
        XCTAssertEqual(status, .downloading(fraction: 0.62))
        caller.cancel()
        _ = await caller.result
    }

    func testTheThrottleReportsForwardStepsAndTheEndOnce() {
        let throttle = ProgressThrottle(step: 0.1)
        XCTAssertEqual(
            [0, 0.05, 0.1, 0.15, 0.2, 0.19, 0.5, 1, 1].map { throttle.shouldReport($0) },
            [true, false, true, false, true, false, true, true, false])
    }
}

/// A fetch that never finishes until cancelled.
final class HangingNeedleFetcher: NeedleFileFetching {
    private let state = Mutex((started: false, cancelled: false))
    var started: Bool { state.withLock { $0.started } }
    var sawCancellation: Bool { state.withLock { $0.cancelled } }

    func fetch(_ url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        state.withLock { $0.started = true }
        do {
            try await Task.sleep(for: .seconds(60))
        } catch {
            state.withLock { $0.cancelled = true }
            throw error
        }
        throw URLError(.timedOut)
    }
}

/// Reports `steps` progress callbacks, as URLSession does per chunk, then serves the bytes.
final class ChattyNeedleFetcher: NeedleFileFetching {
    private let bytes: Data
    private let steps: Int

    init(bytes: Data, steps: Int) {
        self.bytes = bytes
        self.steps = steps
    }

    func fetch(_ url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        for step in 0...steps { progress(Double(step) / Double(steps)) }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("chatty-\(UUID().uuidString).cact")
        try bytes.write(to: file)
        return file
    }
}
