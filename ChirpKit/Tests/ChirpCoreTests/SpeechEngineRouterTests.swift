import Foundation
import XCTest

@testable import ChirpCore

/// M7 Step 1: the live/final routes, the snapshot a job takes when it is queued, and the meeting lease.
final class SpeechEngineRouterTests: XCTestCase {
    /// A speech engine that records what it was asked to do.
    actor RecordingEngine: SpeechEngine {
        nonisolated let descriptor: EngineDescriptor
        private var status: ModelAssetStatus
        private(set) var transcribedFiles: [URL] = []
        private(set) var fileExistedAtTranscribe: [Bool] = []
        private(set) var downloads = 0
        private let reply: String

        init(id: String, status: ModelAssetStatus = .ready(bytesOnDisk: 1), reply: String = "hello") {
            self.descriptor = EngineDescriptor(
                id: id, kind: .speech, provider: "Test", displayName: id, locality: .onDevice, license: "MIT",
                providesWordTimestamps: true)
            self.status = status
            self.reply = reply
        }

        func assetStatus() async -> ModelAssetStatus { status }
        func downloadAssets(progress: @escaping @Sendable (Double) -> Void) async throws {
            downloads += 1
            status = .ready(bytesOnDisk: 1)
            progress(1)
        }
        func deleteAssets() async throws { status = .notDownloaded }
        func prepare() async throws {}
        func transcribe(
            fileAt url: URL, options: SpeechTranscriptionOptions, progress: @escaping @Sendable (Double) -> Void
        ) async throws -> SpeechResult {
            transcribedFiles.append(url)
            fileExistedAtTranscribe.append(FileManager.default.fileExists(atPath: url.path))
            return SpeechResult(text: reply, words: [], language: nil, engineID: descriptor.id, engineVariant: nil)
        }
    }

    /// An engine with its own live mode.
    final class LiveProvidingEngine: SpeechEngine, LiveSpeechSessionProviding, @unchecked Sendable {
        let descriptor = EngineDescriptor(
            id: "test.native-live", kind: .speech, provider: "Test", displayName: "Native", locality: .onDevice,
            license: "MIT")
        private let lock = NSLock()
        private var sessions = 0
        var sessionCount: Int { lock.withLock { sessions } }

        func assetStatus() async -> ModelAssetStatus { .ready(bytesOnDisk: 1) }
        func downloadAssets(progress: @escaping @Sendable (Double) -> Void) async throws {}
        func deleteAssets() async throws {}
        func prepare() async throws {}
        func transcribe(
            fileAt url: URL, options: SpeechTranscriptionOptions, progress: @escaping @Sendable (Double) -> Void
        ) async throws -> SpeechResult {
            SpeechResult(text: "native", words: [], language: nil, engineID: descriptor.id, engineVariant: nil)
        }
        func makeLiveSession(
            scheduler: SpeechJobScheduler, options: SpeechTranscriptionOptions
        ) async -> (any LiveSpeechSession)? {
            lock.withLock { sessions += 1 }
            return TailWindowPreviewSession(scheduler: scheduler) { _ in "native" }
        }
    }

    private let parakeetKey = SpeechEngineVariantKey(
        engineID: SpeechEngineCapabilityRegistry.parakeetEngineID, variant: "v3")
    private let whisperKey = SpeechEngineVariantKey(
        engineID: SpeechEngineCapabilityRegistry.whisperKitEngineID, variant: "base")
    private let appleKey = SpeechEngineVariantKey(engineID: SpeechEngineCapabilityRegistry.appleSpeechEngineID)

    private func makeRouter(
        parakeet: any SpeechEngine = RecordingEngine(id: SpeechEngineCapabilityRegistry.parakeetEngineID),
        whisper: any SpeechEngine = RecordingEngine(id: SpeechEngineCapabilityRegistry.whisperKitEngineID),
        selection: SpeechRouteSelection = .default,
        saved: LockedLog<SpeechRouteSelection> = LockedLog()
    ) -> SpeechEngineRouter {
        SpeechEngineRouter(
            engines: [.init(key: parakeetKey, engine: parakeet), .init(key: whisperKey, engine: whisper)],
            selection: selection, onSelectionChange: { saved.append($0) })
    }

    func testTheDefaultIsParakeetOnBothRoutes() {
        let router = makeRouter()
        XCTAssertEqual(router.engine(for: .live).descriptor.id, SpeechEngineCapabilityRegistry.parakeetEngineID)
        XCTAssertEqual(router.engine(for: .final).descriptor.id, SpeechEngineCapabilityRegistry.parakeetEngineID)
        XCTAssertEqual(router.descriptor.id, SpeechEngineCapabilityRegistry.parakeetEngineID, "as an engine: final")
    }

    func testRoutesAreChosenSeparatelyAndSaved() throws {
        let saved = LockedLog<SpeechRouteSelection>()
        let router = makeRouter(saved: saved)
        try router.select(whisperKey, for: .final)
        XCTAssertEqual(router.engine(for: .final).descriptor.id, SpeechEngineCapabilityRegistry.whisperKitEngineID)
        XCTAssertEqual(router.engine(for: .live).descriptor.id, SpeechEngineCapabilityRegistry.parakeetEngineID)
        XCTAssertEqual(saved.values.last?.final, whisperKey)
        XCTAssertEqual(
            saved.values.last?.live, SpeechEngineCapabilityRegistry.defaultKey, "the other route is untouched")
        try router.select(whisperKey, for: .final)
        XCTAssertEqual(saved.values.count, 1, "choosing the same engine again saves nothing")
    }

    func testAJobKeepsTheEngineItResolvedWhenItWasQueued() async throws {
        let router = makeRouter()
        let queued = SpeechRouting.resolve(router, for: .final)
        try router.select(whisperKey, for: .final)
        let result = try await queued.transcribe(
            fileAt: URL(fileURLWithPath: "/tmp/x.wav"), options: .init(), progress: { _ in })
        XCTAssertEqual(result.engineID, SpeechEngineCapabilityRegistry.parakeetEngineID)
        XCTAssertEqual(
            SpeechRouting.resolve(router, for: .final).descriptor.id, SpeechEngineCapabilityRegistry.whisperKitEngineID,
            "the next job gets the new choice")
    }

    func testResolveOfAPlainEngineIsTheEngineItself() {
        let engine = RecordingEngine(id: "plain")
        XCTAssertEqual(SpeechRouting.resolve(engine, for: .live).descriptor.id, "plain")
        XCTAssertNil(SpeechRouting.beginLease(on: engine))
    }

    func testAMeetingLeaseBlocksRouteChangesUntilItEnds() throws {
        let router = makeRouter()
        let lease = try XCTUnwrap(SpeechRouting.beginLease(on: router))
        XCTAssertEqual(lease.selection, router.selection)
        XCTAssertThrowsError(try router.select(whisperKey, for: .final)) {
            XCTAssertEqual($0 as? SpeechRouteError, .meetingInProgress)
        }
        XCTAssertEqual(router.engine(for: .final).descriptor.id, SpeechEngineCapabilityRegistry.parakeetEngineID)
        SpeechRouting.endLease(lease, on: router)
        XCTAssertEqual(router.activeLeaseCount, 0)
        XCTAssertNoThrow(try router.select(whisperKey, for: .final))
    }

    func testAnEngineNotInTheBuildIsRefused() {
        let router = makeRouter()
        XCTAssertThrowsError(try router.select(appleKey, for: .final)) {
            XCTAssertEqual($0 as? SpeechRouteError, .engineNotInBuild("Apple Speech"))
        }
    }

    func testASavedChoiceThatIsNotInTheBuildFallsBackToTheFirstEngine() {
        let router = makeRouter(selection: SpeechRouteSelection(live: appleKey, final: whisperKey))
        XCTAssertEqual(router.selection.live, parakeetKey)
        XCTAssertEqual(router.selection.final, whisperKey)
    }

    func testAKeyWithoutAVariantFindsTheEnginesInstance() {
        let router = makeRouter()
        let open = SpeechEngineVariantKey(engineID: SpeechEngineCapabilityRegistry.parakeetEngineID)
        XCTAssertEqual(router.registeredKey(for: open), parakeetKey)
        XCTAssertNotNil(router.registeredEngine(for: open))
    }

    func testAsAnEngineTheRouterIsTheFinalRoute() async throws {
        let whisper = RecordingEngine(id: SpeechEngineCapabilityRegistry.whisperKitEngineID, status: .notDownloaded)
        let router = makeRouter(whisper: whisper)
        try router.select(whisperKey, for: .final)
        let status = await router.assetStatus()
        XCTAssertEqual(status, .notDownloaded)
        try await router.downloadAssets { _ in }
        let downloads = await whisper.downloads
        XCTAssertEqual(downloads, 1)
    }

    func testTheLiveRouteUsesTheEnginesOwnLiveMode() async throws {
        let native = LiveProvidingEngine()
        let router = SpeechEngineRouter(
            engines: [.init(key: parakeetKey, engine: native)], selection: .default)
        let session = await router.makeLiveSession(scheduler: SpeechJobScheduler(), options: .init())
        XCTAssertNotNil(session)
        XCTAssertEqual(native.sessionCount, 1)
        await session?.finish()
    }

    func testALiveEngineWithoutALiveModePreviewsThroughATemporaryWAVThatIsDeleted() async throws {
        let whisper = RecordingEngine(id: SpeechEngineCapabilityRegistry.whisperKitEngineID, reply: "tail text")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "router-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let router = SpeechEngineRouter(
            engines: [
                .init(key: parakeetKey, engine: RecordingEngine(id: "p")), .init(key: whisperKey, engine: whisper),
            ],
            selection: SpeechRouteSelection(live: whisperKey, final: parakeetKey), temporaryDirectory: directory)
        let made = await router.makeLiveSession(scheduler: SpeechJobScheduler(), options: .init())
        let session = try XCTUnwrap(made as? TailWindowPreviewSession)
        var updates = session.updates.makeAsyncIterator()
        await session.append([Float](repeating: 0.1, count: 16_000))
        await session.tick()
        let text = await updates.next()
        XCTAssertEqual(text, "tail text")
        let existed = await whisper.fileExistedAtTranscribe
        XCTAssertEqual(existed, [true])
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(leftovers, [], "each pass deletes its WAV")
        await session.finish()
    }

    func testNoLiveSessionWhileTheLiveEnginesModelIsMissing() async throws {
        let whisper = RecordingEngine(id: SpeechEngineCapabilityRegistry.whisperKitEngineID, status: .notDownloaded)
        let router = makeRouter(whisper: whisper, selection: SpeechRouteSelection(live: whisperKey, final: parakeetKey))
        let session = await router.makeLiveSession(scheduler: SpeechJobScheduler(), options: .init())
        XCTAssertNil(session)
        let downloads = await whisper.downloads
        XCTAssertEqual(downloads, 0, "never downloads")
    }

    func testSelectionDecodingIsForgiving() throws {
        let data = Data(#"{"final":{"engineID":"argmax.whisperkit","variant":"base"},"live":42}"#.utf8)
        let decoded = try JSONDecoder().decode(SpeechRouteSelection.self, from: data)
        XCTAssertEqual(decoded.final, whisperKey)
        XCTAssertEqual(decoded.live, SpeechEngineCapabilityRegistry.defaultKey)
    }
}
