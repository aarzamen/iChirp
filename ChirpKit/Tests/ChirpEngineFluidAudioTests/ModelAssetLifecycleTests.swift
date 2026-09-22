import ChirpCore
import XCTest

@testable import ChirpEngineFluidAudio

/// The race rules shared by both FluidAudio engines, driven by fake hooks: no real models, no timing
/// assumptions (every wait is on an observable event).
final class ModelAssetLifecycleTests: XCTestCase {
    /// Fake FluidAudio: files exist until `remove`. Download runs until released (and honors cancellation); load
    /// optionally blocks on a latch that ignores cancellation, like a CoreML compile.
    private final class FakeAssets: @unchecked Sendable {
        // @unchecked Sendable: mutable state is only touched while `lock` is held.
        private let lock = NSLock()
        private var present: Bool
        private var downloadReleased = false
        private var loads = 0
        private var log: [String] = []
        private let loadBlocks: Bool
        let loadLatch = Latch()

        init(present: Bool, loadBlocks: Bool = false) {
            self.present = present
            self.loadBlocks = loadBlocks
        }

        private func locked<T>(_ body: () -> T) -> T {
            lock.lock()
            defer { lock.unlock() }
            return body()
        }

        var events: [String] { locked { log } }
        var loadCount: Int { locked { loads } }
        var isPresent: Bool { locked { present } }
        func record(_ event: String) { locked { log.append(event) } }
        func releaseDownload() { locked { downloadReleased = true } }
        private var isDownloadReleased: Bool { locked { downloadReleased } }

        func hooks() -> ModelAssetLifecycle<Int>.Hooks {
            ModelAssetLifecycle<Int>.Hooks(
                engineID: "fake.model",
                displayName: "Fake model",
                modelsPresent: { self.isPresent },
                bytesOnDisk: { 42 },
                download: { _ in
                    self.record("download-start")
                    do {
                        while !self.isDownloadReleased {
                            try await Task.sleep(for: .milliseconds(1))
                        }
                    } catch {
                        self.record("download-cancelled")
                        throw error
                    }
                    self.locked { self.present = true }
                    self.record("download-end")
                },
                load: {
                    let number = self.locked {
                        self.loads += 1
                        self.log.append("load-start")
                        return self.loads
                    }
                    if self.loadBlocks {
                        await self.loadLatch.wait()
                    }
                    self.record("load-end")
                    return number
                },
                remove: {
                    self.record("remove")
                    self.locked { self.present = false }
                }
            )
        }
    }

    func testPrepareDuringADownloadThrowsModelNotDownloadedAndStartsNoLoad() async throws {
        // Files already look present (a re-download): the in-flight download alone must block loading.
        let assets = FakeAssets(present: true)
        let lifecycle = ModelAssetLifecycle(hooks: assets.hooks())
        let download = Task { try await lifecycle.download { _ in } }
        await waitUntil { assets.events.contains("download-start") }

        await assertThrowsModelNotDownloaded { try await lifecycle.prepare() }
        await assertThrowsModelNotDownloaded { _ = try await lifecycle.acquire() }
        XCTAssertEqual(assets.loadCount, 0, "no load may start while a download writes the files")

        assets.releaseDownload()
        try await download.value
        try await lifecycle.prepare()
        XCTAssertEqual(assets.loadCount, 1)
        let isLoaded = await lifecycle.isLoaded
        XCTAssertTrue(isLoaded)
    }

    func testDeleteDuringADownloadCancelsAndAwaitsItBeforeRemovingFiles() async throws {
        let assets = FakeAssets(present: false)
        let lifecycle = ModelAssetLifecycle(hooks: assets.hooks())
        let download = Task { try await lifecycle.download { _ in } }
        await waitUntil { assets.events.contains("download-start") }

        try await lifecycle.delete()

        XCTAssertEqual(assets.events, ["download-start", "download-cancelled", "remove"])
        do {
            try await download.value
            XCTFail("The download should have been cancelled by the delete")
        } catch {
            XCTAssertEqual(error as? SpeechEngineError, .cancelled)
        }
        let statusAfterDelete = await lifecycle.status()
        XCTAssertEqual(statusAfterDelete, .notDownloaded)

        // A download right after the delete starts a fresh job instead of joining the cancelled one.
        assets.releaseDownload()
        try await lifecycle.download { _ in }
        XCTAssertEqual(assets.events.filter { $0 == "download-start" }.count, 2)
        let statusAfterDownload = await lifecycle.status()
        XCTAssertEqual(statusAfterDownload, .ready(bytesOnDisk: 42))
    }

    func testALoadThatFinishesAfterADeleteIsDiscarded() async throws {
        let assets = FakeAssets(present: true, loadBlocks: true)
        let lifecycle = ModelAssetLifecycle(hooks: assets.hooks())
        let prepare = Task { try await lifecycle.prepare() }
        await waitUntil { assets.events.contains("load-start") }

        let delete = Task { try await lifecycle.delete() }
        await waitUntil { await lifecycle.isDeleting }
        XCTAssertFalse(assets.events.contains("remove"), "files must not be removed while the load reads them")

        await assets.loadLatch.open()
        try await delete.value

        await assertThrowsModelNotDownloaded { try await prepare.value }
        XCTAssertEqual(assets.events, ["load-start", "load-end", "remove"])
        let isLoaded = await lifecycle.isLoaded
        XCTAssertFalse(isLoaded, "the stale load must not be installed")
        let status = await lifecycle.status()
        XCTAssertEqual(status, .notDownloaded)
        await assertThrowsModelNotDownloaded { _ = try await lifecycle.acquire() }
    }

    func testDeleteIsRefusedWhileALeaseIsOut() async throws {
        let assets = FakeAssets(present: true)
        let lifecycle = ModelAssetLifecycle(hooks: assets.hooks())
        let lease = try await lifecycle.acquire()

        do {
            try await lifecycle.delete()
            XCTFail("Delete must refuse while a job holds the model")
        } catch {
            XCTAssertEqual(
                error as? SpeechEngineError,
                .underlying(ModelAssetLifecycle<Int>.inUseMessage(for: "Fake model")))
        }
        XCTAssertFalse(assets.events.contains("remove"))
        let stillLoaded = await lifecycle.isLoaded
        XCTAssertTrue(stillLoaded)

        await lifecycle.release(lease)
        try await lifecycle.delete()
        XCTAssertTrue(assets.events.contains("remove"))
        let loadedAfterDelete = await lifecycle.isLoaded
        XCTAssertFalse(loadedAfterDelete)
        let leases = await lifecycle.activeLeaseCount
        XCTAssertEqual(leases, 0)
    }

    func testConcurrentPreparesShareOneLoad() async throws {
        let assets = FakeAssets(present: true, loadBlocks: true)
        let lifecycle = ModelAssetLifecycle(hooks: assets.hooks())
        let first = Task { try await lifecycle.prepare() }
        let second = Task { try await lifecycle.prepare() }
        await waitUntil { assets.loadCount == 1 }

        await assets.loadLatch.open()
        try await first.value
        try await second.value
        try await lifecycle.prepare()
        XCTAssertEqual(assets.loadCount, 1)
    }
}
