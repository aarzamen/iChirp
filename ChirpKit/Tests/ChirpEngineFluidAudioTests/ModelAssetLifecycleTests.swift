import ChirpCore
import FluidAudio
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
        let lifecycle = ModelAssetLifecycle(hooks: assets.hooks(), network: .testing())
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
        let lifecycle = ModelAssetLifecycle(hooks: assets.hooks(), network: .testing())
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
        let lifecycle = ModelAssetLifecycle(hooks: assets.hooks(), network: .testing())
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
        let lifecycle = ModelAssetLifecycle(hooks: assets.hooks(), network: .testing())
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
        let lifecycle = ModelAssetLifecycle(hooks: assets.hooks(), network: .testing())
        let first = Task { try await lifecycle.prepare() }
        let second = Task { try await lifecycle.prepare() }
        await waitUntil { assets.loadCount == 1 }

        await assets.loadLatch.open()
        try await first.value
        try await second.value
        try await lifecycle.prepare()
        XCTAssertEqual(assets.loadCount, 1)
    }

    // MARK: - Network: retries, offline, readable failures

    /// A download hook that plays back one outcome per attempt (nil succeeds and makes the files present), reporting
    /// `phase` to the progress handler first, as FluidAudio does before its listing request.
    private final class ScriptedDownload: @unchecked Sendable {
        // @unchecked Sendable: mutable state is only touched while `lock` is held.
        private let lock = NSLock()
        private var outcomes: [(any Error)?]
        private var present: Bool
        private var calls = 0
        private let phase: DownloadPhase?

        init(_ outcomes: [(any Error)?], present: Bool = false, phase: DownloadPhase? = nil) {
            self.outcomes = outcomes
            self.present = present
            self.phase = phase
        }

        private func locked<T>(_ body: () -> T) -> T {
            lock.lock()
            defer { lock.unlock() }
            return body()
        }

        var attempts: Int { locked { calls } }

        func hooks() -> ModelAssetLifecycle<Int>.Hooks {
            ModelAssetLifecycle<Int>.Hooks(
                engineID: "fake.model",
                displayName: "Fake model",
                modelsPresent: { self.locked { self.present } },
                bytesOnDisk: { 42 },
                download: { handler in
                    let outcome = self.locked { () -> (any Error)? in
                        self.calls += 1
                        return self.outcomes.isEmpty ? nil : self.outcomes.removeFirst()
                    }
                    if let phase = self.phase {
                        handler(DownloadProgress(fractionCompleted: 0, phase: phase))
                    }
                    if let outcome { throw outcome }
                    self.locked { self.present = true }
                },
                load: { 1 },
                remove: {}
            )
        }
    }

    private static let listingURL = URL(
        string: "https://huggingface.co/api/models/FluidInference/parakeet-tdt-0.6b-v3-coreml/tree/main")!

    private func downloadError(
        _ lifecycle: ModelAssetLifecycle<Int>, file: StaticString = #filePath, line: UInt = #line
    ) async -> SpeechEngineError? {
        do {
            try await lifecycle.download { _ in }
            XCTFail("The download should have failed", file: file, line: line)
            return nil
        } catch {
            guard let engineError = error as? SpeechEngineError else {
                XCTFail("Expected SpeechEngineError, got \(error)", file: file, line: line)
                return nil
            }
            return engineError
        }
    }

    func testTheLiveScheduleIsThreeRetriesAfter2And8And20Seconds() {
        XCTAssertEqual(DownloadNetworkPolicy.live.retryDelays, [.seconds(2), .seconds(8), .seconds(20)])
    }

    func testTransientFailuresAreRetriedWithBackoffUntilTheDownloadSucceeds() async throws {
        let script = ScriptedDownload([URLError(.timedOut), URLError(.networkConnectionLost), nil])
        let sleeps = LockedLog<Duration>()
        let lifecycle = ModelAssetLifecycle(hooks: script.hooks(), network: .testing(sleeps: sleeps))

        let progress = LockedLog<Double>()
        try await lifecycle.download { progress.append($0) }

        XCTAssertEqual(script.attempts, 3)
        XCTAssertEqual(sleeps.values, [.seconds(2), .seconds(8)])
        XCTAssertEqual(progress.values.last, 1)
        let status = await lifecycle.status()
        XCTAssertEqual(status, .ready(bytesOnDisk: 42))
    }

    /// The iPhone 17 Pro's failure: FluidAudio's listing request timed out. After three retries the recorded
    /// failure keeps the owner-facing sentence first, then the error code, the failing host and the phase.
    func testAfterThreeRetriesTheFailureKeepsTheCodeHostAndPhase() async throws {
        let timeout = URLError(.timedOut, userInfo: [NSURLErrorFailingURLErrorKey: Self.listingURL])
        let script = ScriptedDownload(Array(repeating: timeout, count: 6), phase: .listing)
        let sleeps = LockedLog<Duration>()
        let lifecycle = ModelAssetLifecycle(hooks: script.hooks(), network: .testing(sleeps: sleeps))

        guard case .underlying(let message) = await downloadError(lifecycle) else {
            return XCTFail("Expected an .underlying failure message")
        }
        XCTAssertEqual(script.attempts, 4, "the first attempt plus three retries")
        XCTAssertEqual(sleeps.values, [.seconds(2), .seconds(8), .seconds(20)])

        let sentence = try XCTUnwrap(SpeechEngineError.failureMessage(for: timeout))
        XCTAssertTrue(message.hasPrefix(sentence), message)
        let details = message.dropFirst(sentence.count)
        for part in ["URLError -1001", "huggingface.co", "listing", "4 attempts"] {
            XCTAssertTrue(details.contains(part), "missing \(part): \(message)")
        }
        let status = await lifecycle.status()
        XCTAssertEqual(status, .failed(message: message), "the tracker records the same message")
    }

    func testFluidAudioStalledAndRateLimitedDownloadsAreRetried() async throws {
        let script = ScriptedDownload([
            DownloadError.stalled(path: "Encoder.mlmodelc/weights/weight.bin", window: 120),
            DownloadError.rateLimited(statusCode: 429, message: "Rate limited while listing files (HTTP 429)"),
            nil,
        ])
        let lifecycle = ModelAssetLifecycle(hooks: script.hooks(), network: .testing())

        try await lifecycle.download { _ in }
        XCTAssertEqual(script.attempts, 3)
    }

    func testATransientErrorWrappedAsAnUnderlyingErrorIsRetried() async throws {
        let wrapped = NSError(
            domain: "FluidAudio.Test", code: 7, userInfo: [NSUnderlyingErrorKey: URLError(.cannotFindHost)])
        let script = ScriptedDownload([wrapped, URLError(.dnsLookupFailed), URLError(.cannotConnectToHost), nil])
        let lifecycle = ModelAssetLifecycle(hooks: script.hooks(), network: .testing())

        try await lifecycle.download { _ in }
        XCTAssertEqual(script.attempts, 4)
    }

    /// Retrying cannot fix these: a bad server answer, a full disk, or cellular data switched off for the app.
    func testPermanentFailuresAreNotRetried() async throws {
        let permanent: [any Error] = [
            URLError(.badServerResponse), URLError(.dataNotAllowed), DownloadError.invalidResponse,
            CocoaError(.fileWriteOutOfSpace),
        ]
        for error in permanent {
            let script = ScriptedDownload([error, nil])
            let sleeps = LockedLog<Duration>()
            let lifecycle = ModelAssetLifecycle(hooks: script.hooks(), network: .testing(sleeps: sleeps))

            _ = await downloadError(lifecycle)
            XCTAssertEqual(script.attempts, 1, "\(error)")
            XCTAssertEqual(sleeps.values, [], "\(error)")
        }
    }

    func testCancellingDuringABackoffStopsTheRetriesAtOnce() async throws {
        let script = ScriptedDownload([URLError(.timedOut), nil])
        let sleeps = LockedLog<Duration>()
        // A real, long sleep: only cancellation can end it.
        let policy = DownloadNetworkPolicy.testing(sleeps: sleeps) { _ in try await Task.sleep(for: .seconds(3600)) }
        let lifecycle = ModelAssetLifecycle(hooks: script.hooks(), network: policy)

        let download = Task { try await lifecycle.download { _ in } }
        await waitUntil { sleeps.values.count == 1 }
        download.cancel()

        do {
            try await download.value
            XCTFail("The download should have been cancelled")
        } catch {
            XCTAssertEqual(error as? SpeechEngineError, .cancelled)
        }
        XCTAssertEqual(script.attempts, 1, "no retry may start after cancellation")
        let status = await lifecycle.status()
        XCTAssertEqual(status, .notDownloaded, "a cancelled download is not a failure")
    }

    func testAnOfflinePhoneFailsAtOnceWithoutTryingTheDownload() async throws {
        let script = ScriptedDownload([nil])
        let reason = "cellular data is turned off for this app"
        let lifecycle = ModelAssetLifecycle(
            hooks: script.hooks(), network: .testing(path: .unusable(reason: reason)))

        guard case .underlying(let message) = await downloadError(lifecycle) else {
            return XCTFail("Expected an .underlying failure message")
        }
        XCTAssertEqual(script.attempts, 0, "no request is sent without a network path")
        XCTAssertTrue(message.hasPrefix(SpeechEngineError.noInternetMessage), message)
        XCTAssertTrue(message.contains(reason), message)
        let status = await lifecycle.status()
        XCTAssertEqual(status, .failed(message: message))
    }

    /// With every file already on disk, FluidAudio's download only validates the cache, so it must work offline.
    func testTheNetworkCheckIsSkippedWhenTheFilesAreComplete() async throws {
        let script = ScriptedDownload([nil], present: true)
        let lifecycle = ModelAssetLifecycle(
            hooks: script.hooks(), network: .testing(path: .unusable(reason: "no Wi-Fi or cellular connection")))

        try await lifecycle.download { _ in }
        XCTAssertEqual(script.attempts, 1)
    }

    func testAnUnansweredNetworkCheckLetsTheDownloadTry() async throws {
        let script = ScriptedDownload([nil])
        let lifecycle = ModelAssetLifecycle(hooks: script.hooks(), network: .testing(path: .unknown))

        try await lifecycle.download { _ in }
        XCTAssertEqual(script.attempts, 1)
    }
}
