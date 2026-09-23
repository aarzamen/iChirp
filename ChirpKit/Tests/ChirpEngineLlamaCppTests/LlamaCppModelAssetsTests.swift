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
}
