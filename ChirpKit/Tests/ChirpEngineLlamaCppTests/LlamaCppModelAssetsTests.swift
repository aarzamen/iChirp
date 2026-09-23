import ChirpCore
import Foundation
import Synchronization
import XCTest

@testable import ChirpEngineLlamaCpp

/// Explicit download, size and SHA-256 checks, free space, adoption of a file already on disk, delete.
final class LlamaCppModelAssetsTests: XCTestCase {
    private var directory: URL!
    private let bytes = Data("synthetic gguf weights".utf8)

    override func setUp() async throws {
        directory = try LlamaTestSupport.temporaryDirectory()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func assets(
        spec: LlamaCppModelSpec? = nil, fetcher: FakeFileFetcher? = nil, freeSpace: Int64? = nil,
        willDelete: @escaping @Sendable () async -> Void = {}
    ) -> (LlamaCppModelAssets, FakeFileFetcher) {
        let fetcher = fetcher ?? FakeFileFetcher(bytes: bytes)
        let assets = LlamaCppModelAssets(
            spec: spec ?? LlamaTestSupport.spec(bytes: bytes), modelsDirectory: directory, fetcher: fetcher,
            freeSpace: { _ in freeSpace }, willDelete: willDelete)
        return (assets, fetcher)
    }

    func testNothingIsDownloadedUntilAsked() async {
        let (assets, fetcher) = assets()
        let status = await assets.assetStatus()
        XCTAssertEqual(status, .notDownloaded)
        XCTAssertFalse(assets.isReady)
        XCTAssertEqual(fetcher.fetchCount, 0)
    }

    func testDownloadVerifiesAndKeepsTheFile() async throws {
        let (assets, fetcher) = assets()
        let fractions = Mutex<[Double]>([])
        try await assets.downloadAssets { fraction in fractions.withLock { $0.append(fraction) } }
        XCTAssertTrue(assets.isReady)
        let status = await assets.assetStatus()
        XCTAssertEqual(status, .ready(bytesOnDisk: Int64(bytes.count)))
        XCTAssertEqual(fetcher.fetchCount, 1)
        XCTAssertEqual(fractions.withLock { $0.last }, 1)
        XCTAssertEqual(try Data(contentsOf: assets.modelURL), bytes)
        XCTAssertTrue(assets.modelURL.path.contains("/llm/test-model/"))
        let excluded = try assets.directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup
        XCTAssertEqual(excluded, true, "a model can be downloaded again, so it stays out of backups")
        // A second tap does nothing.
        try await assets.downloadAssets { _ in }
        XCTAssertEqual(fetcher.fetchCount, 1)
    }

    func testAHashMismatchKeepsNothing() async throws {
        var spec = LlamaTestSupport.spec(bytes: bytes)
        spec.sha256 = String(repeating: "0", count: 64)
        let (assets, _) = assets(spec: spec)
        do {
            try await assets.downloadAssets { _ in }
            XCTFail("expected a hash mismatch")
        } catch {
            XCTAssertEqual(error as? LlamaCppModelAssets.AssetError, .hashMismatch)
        }
        XCTAssertFalse(assets.isReady)
        XCTAssertFalse(FileManager.default.fileExists(atPath: assets.modelURL.path))
        guard case .failed = await assets.assetStatus() else { return XCTFail("expected failed") }
    }

    func testAWrongSizeKeepsNothing() async throws {
        let (assets, _) = assets(fetcher: FakeFileFetcher(bytes: Data("short".utf8)))
        do {
            try await assets.downloadAssets { _ in }
            XCTFail("expected a size mismatch")
        } catch {
            XCTAssertEqual(error as? LlamaCppModelAssets.AssetError, .sizeMismatch(5))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: assets.modelURL.path))
    }

    func testNotEnoughFreeSpaceFailsBeforeDownloading() async throws {
        let (assets, fetcher) = assets(freeSpace: 1_000)
        do {
            try await assets.downloadAssets { _ in }
            XCTFail("expected not enough space")
        } catch {
            guard case .notEnoughSpace? = error as? LlamaCppModelAssets.AssetError else {
                return XCTFail("got \(error)")
            }
            XCTAssertTrue(error.localizedDescription.contains("Not enough free storage"))
        }
        XCTAssertEqual(fetcher.fetchCount, 0)
    }

    func testAFileAlreadyOnDiskIsVerifiedInsteadOfDownloaded() async throws {
        let (assets, fetcher) = assets()
        try FileManager.default.createDirectory(at: assets.directory, withIntermediateDirectories: true)
        try bytes.write(to: assets.modelURL)
        XCTAssertFalse(assets.isReady, "not ready until its hash is checked")
        try await assets.downloadAssets { _ in }
        XCTAssertTrue(assets.isReady)
        XCTAssertEqual(fetcher.fetchCount, 0)
    }

    func testDeleteUnloadsFirstThenRemovesTheFolder() async throws {
        let calls = Mutex(0)
        let (assets, _) = assets(willDelete: { calls.withLock { $0 += 1 } })
        try await assets.downloadAssets { _ in }
        try await assets.deleteAssets()
        XCTAssertEqual(calls.withLock { $0 }, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: assets.directory.path))
        let status = await assets.assetStatus()
        XCTAssertEqual(status, .notDownloaded)
    }

    func testConcurrentDownloadsShareOneFetch() async throws {
        let (assets, fetcher) = assets()
        async let first: Void = assets.downloadAssets { _ in }
        async let second: Void = assets.downloadAssets { _ in }
        _ = try await (first, second)
        XCTAssertEqual(fetcher.fetchCount, 1)
        XCTAssertTrue(assets.isReady)
    }

    // MARK: - Review minors 3 and 5

    /// The continued-processing expiration cancels the task that called `downloadAssets`; that must stop the fetch.
    func testCancellingTheCallerStopsTheDownload() async throws {
        let fetcher = HangingFileFetcher()
        let assets = LlamaCppModelAssets(
            spec: LlamaTestSupport.spec(bytes: bytes), modelsDirectory: directory, fetcher: fetcher,
            freeSpace: { _ in nil })
        let caller = Task { try await assets.downloadAssets { _ in } }
        let started = await LlamaTestSupport.waitUntil { fetcher.started }
        XCTAssertTrue(started)
        caller.cancel()
        let stopped = await LlamaTestSupport.waitUntil { fetcher.sawCancellation }
        XCTAssertTrue(stopped, "the fetch inside the unstructured task was cancelled")
        do {
            try await caller.value
            XCTFail("a cancelled download does not succeed")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        let status = await assets.assetStatus()
        XCTAssertNotEqual(status, .ready(bytesOnDisk: Int64(bytes.count)))
        XCTAssertFalse(assets.isReady)
    }

    /// Tens of thousands of URLSession callbacks become at most ~200 forward steps.
    func testProgressIsThrottledAndNeverGoesBackwards() async throws {
        let fetcher = ChattyFileFetcher(bytes: bytes, steps: 20_000)
        let assets = LlamaCppModelAssets(
            spec: LlamaTestSupport.spec(bytes: bytes), modelsDirectory: directory, fetcher: fetcher,
            freeSpace: { _ in nil })
        let seen = Mutex<[Double]>([])
        try await assets.downloadAssets { fraction in seen.withLock { $0.append(fraction) } }
        let reported = seen.withLock { $0 }
        XCTAssertLessThanOrEqual(reported.count, 202)
        XCTAssertEqual(reported, reported.sorted(), "never backwards")
        XCTAssertEqual(reported.last, 1)
        XCTAssertTrue(assets.isReady)
    }

    func testTheThrottleReportsForwardStepsAndTheEndOnce() {
        let throttle = ProgressThrottle(step: 0.1)
        XCTAssertEqual(
            [0, 0.05, 0.1, 0.15, 0.2, 0.19, 0.5, 1, 1].map { throttle.shouldReport($0) },
            [true, false, true, false, true, false, true, true, false])
    }
}

/// A fetch that never finishes until cancelled.
final class HangingFileFetcher: LlamaFileFetching {
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
final class ChattyFileFetcher: LlamaFileFetching {
    private let bytes: Data
    private let steps: Int

    init(bytes: Data, steps: Int) {
        self.bytes = bytes
        self.steps = steps
    }

    func fetch(_ url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        for step in 0...steps { progress(Double(step) / Double(steps)) }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("chatty-\(UUID().uuidString).gguf")
        try bytes.write(to: file)
        return file
    }
}
