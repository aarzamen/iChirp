import ChirpCore
import XCTest

@testable import ChirpFeatures

/// M7 Step 1: files, meetings and dictation go through the router's routes; a job keeps the engine it was queued
/// with; a meeting holds the lease from start to its saved state.
@MainActor
final class SpeechRouteConsumersTests: XCTestCase {
    private let keyA = SpeechEngineVariantKey(engineID: "fake.a")
    private let keyB = SpeechEngineVariantKey(engineID: "fake.b")

    private func makeRouter(_ a: FakeSpeech, _ b: FakeSpeech, final: SpeechEngineVariantKey? = nil)
        -> SpeechEngineRouter
    {
        SpeechEngineRouter(
            engines: [.init(key: keyA, engine: a), .init(key: keyB, engine: b)],
            selection: SpeechRouteSelection(live: keyA, final: final ?? keyA))
    }

    func testAFileIsTranscribedByTheFinalRoutesEngine() async throws {
        let a = FakeSpeech(id: "fake.a")
        let b = FakeSpeech(id: "fake.b")
        let router = makeRouter(a, b, final: keyB)
        let h = try PipelineHarness(testCase: self, engine: router)
        let id = try await h.importSample()

        _ = await h.pipeline.process(id: id)

        let row = await h.store.row(id)
        XCTAssertEqual(row?.status, .completed)
        XCTAssertEqual(row?.engine, "fake.b")
        let (aCalls, bCalls) = (await a.transcribeCalls, await b.transcribeCalls)
        XCTAssertEqual(aCalls, 0)
        XCTAssertEqual(bCalls, 1)
    }

    func testAQueuedFileKeepsItsEngineWhenTheFinalRouteChanges() async throws {
        let a = FakeSpeech(id: "fake.a")
        let b = FakeSpeech(id: "fake.b")
        let router = makeRouter(a, b)
        let hold = await a.holdNextTranscription()
        let h = try PipelineHarness(testCase: self, engine: router)
        let id = try await h.importSample()

        let job = Task { await h.pipeline.process(id: id) }
        await hold.entered.wait()
        try router.select(keyB, for: .final)
        hold.release.fire()
        _ = await job.value

        let row = await h.store.row(id)
        XCTAssertEqual(row?.engine, "fake.a", "the job finishes on the engine it was queued with")
        let bCalls = await b.transcribeCalls
        XCTAssertEqual(bCalls, 0)
    }

    func testAMeetingHoldsTheLeaseUntilItIsSavedAndUsesTheFinalRoute() async throws {
        let a = FakeSpeech(id: "fake.a")
        let b = FakeSpeech(id: "fake.b")
        let router = makeRouter(a, b, final: keyB)
        let h = try MeetingHarness(engine: router)
        defer { h.cleanUp() }

        h.coordinator.start()
        await waitUntil { h.coordinator.state == .recording }
        XCTAssertEqual(router.activeLeaseCount, 1)
        XCTAssertThrowsError(try router.select(keyA, for: .final)) {
            XCTAssertEqual($0 as? SpeechRouteError, .meetingInProgress)
        }
        let id = try XCTUnwrap(h.coordinator.sessionID)
        XCTAssertEqual(h.lockStore.read(sessionId: id)?.speechEngine, "fake.b", "the lock names the final engine")

        h.recorder.send(.samples(toneSamples(seconds: 2)))
        await waitUntil { h.coordinator.recordedSeconds >= 2 }
        h.coordinator.stop()
        await waitUntil { if case .saved = h.coordinator.state { true } else { false } }

        XCTAssertEqual(router.activeLeaseCount, 0, "released once saved")
        let saved = try await h.store.fetch(id: id)
        XCTAssertEqual(saved?.engine, "fake.b")
        XCTAssertNoThrow(try router.select(keyA, for: .final))
    }

    // MARK: - Review I2: a routed engine whose model is missing is named, with what to do

    private let parakeetKey = SpeechEngineVariantKey(
        engineID: SpeechEngineCapabilityRegistry.parakeetEngineID, variant: "v3")
    private let whisperKey = SpeechEngineVariantKey(
        engineID: SpeechEngineCapabilityRegistry.whisperKitEngineID, variant: "base")
    private static let whisperMissing =
        "Whisper Base isn’t downloaded on this iPhone. Download it in Settings → Speech engines, or switch "
        + "Transcripts to Parakeet"

    /// Parakeet (on disk) plus Whisper Base (as `whisperStatus`) on the final route, as a restored backup leaves it.
    private func makeWhisperRouter(
        whisperStatus: ModelAssetStatus = .notDownloaded
    ) -> (SpeechEngineRouter, parakeet: FakeSpeech, whisper: FakeSpeech) {
        let parakeet = FakeSpeech(id: SpeechEngineCapabilityRegistry.parakeetEngineID, displayName: "Parakeet v3")
        let whisper = FakeSpeech(
            status: whisperStatus, id: SpeechEngineCapabilityRegistry.whisperKitEngineID, displayName: "Whisper Base")
        let router = SpeechEngineRouter(
            engines: [.init(key: parakeetKey, engine: parakeet), .init(key: whisperKey, engine: whisper)],
            selection: SpeechRouteSelection(live: parakeetKey, final: whisperKey))
        return (router, parakeet, whisper)
    }

    func testAFileWhoseFinalEngineHasNoModelNamesThatEngineAndRetryWorksAfterSwitching() async throws {
        let (router, _, whisper) = makeWhisperRouter()
        let h = try PipelineHarness(testCase: self, engine: router)
        let id = try await h.importSample()

        _ = await h.pipeline.process(id: id)

        let failed = await h.store.row(id)
        XCTAssertEqual(failed?.status, .failed)
        XCTAssertEqual(failed?.errorMessage, Self.whisperMissing, "never 'download Parakeet' while Parakeet is here")
        let downloads = await whisper.downloadCalls
        XCTAssertEqual(downloads, 0, "nothing downloads silently")

        try router.select(parakeetKey, for: .final)
        let retried = await h.pipeline.retry(id: id)
        XCTAssertEqual(retried?.status, .completed)
        XCTAssertEqual(retried?.engine, SpeechEngineCapabilityRegistry.parakeetEngineID)
    }

    func testAModelThatDisappearsAfterTheCheckIsStillNamed() async throws {
        let (router, _, whisper) = makeWhisperRouter(whisperStatus: .ready(bytesOnDisk: 1))
        await whisper.failPrepare(
            with: SpeechEngineError.modelNotDownloaded(SpeechEngineCapabilityRegistry.whisperKitEngineID))
        let h = try PipelineHarness(testCase: self, engine: router)
        let id = try await h.importSample()

        _ = await h.pipeline.process(id: id)

        let failed = await h.store.row(id)
        XCTAssertEqual(failed?.errorMessage, Self.whisperMissing)
    }

    func testAMeetingFinalPassNamesTheMissingEngineAndKeepsTheRecording() async throws {
        let (router, _, _) = makeWhisperRouter()
        let h = try MeetingHarness(engine: router)
        defer { h.cleanUp() }
        h.coordinator.start()
        await waitUntil { h.coordinator.state == .recording }
        h.recorder.send(.samples(toneSamples(seconds: 2)))
        await waitUntil { h.coordinator.recordedSeconds >= 2 }
        h.coordinator.stop()
        await waitUntil { if case .failed = h.coordinator.state { true } else { false } }

        guard case .failed(let message, let id) = h.coordinator.state else { return XCTFail("expected failed") }
        XCTAssertEqual(message, "The recording is saved. " + Self.whisperMissing + ", then tap Retry.")
        let rowID = try XCTUnwrap(id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: h.audio(rowID).path), "the audio stays for Retry")
        XCTAssertEqual(router.activeLeaseCount, 0, "released after the failed final pass (review M9)")

        try router.select(parakeetKey, for: .final)
        let retried = await h.finalizer.retry(id: rowID)
        XCTAssertEqual(retried?.status, .completed, "Retry works once Transcripts is switched")
    }

    func testDictationRefusesToStartNamingTheMissingFinalEngine() async throws {
        let (router, _, _) = makeWhisperRouter()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("routes-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let capture = FakeCapture()
        let coordinator = DictationCoordinator(
            capture: capture, speech: router, liveSessions: router, scheduler: SpeechJobScheduler(),
            store: FakeStore(), paths: AppPaths(root: root), settings: InMemorySettingsStore(),
            clipboard: FakeClipboard())
        coordinator.start()
        await waitUntil { if case .failed = coordinator.state { true } else { false } }
        XCTAssertEqual(coordinator.state, .failed(Self.whisperMissing))
        XCTAssertEqual(coordinator.failureKind, .speechModelMissing, "the screen offers Settings by kind")
        XCTAssertEqual(capture.starts, 0)
    }

    func testAPlainEngineKeepsTheParakeetDownloadSentence() {
        let error = SpeechModelMissingError(
            engine: FakeSpeech(status: .notDownloaded).descriptor, configured: FakeSpeech(), route: .final)
        XCTAssertEqual(error.message, FileTranscriptionPipeline.modelMissingMessage, "no routes, nothing to switch")
        let parakeet = SpeechModelMissingError(
            engineID: SpeechEngineCapabilityRegistry.parakeetEngineID, engineName: "Parakeet v3", route: .final,
            isRouteChoice: true)
        XCTAssertEqual(parakeet.message, FileTranscriptionPipeline.modelMissingMessage)
        let live = SpeechModelMissingError(
            engineID: SpeechEngineCapabilityRegistry.appleSpeechEngineID, engineName: "Apple Speech", route: .live,
            isRouteChoice: true)
        XCTAssertEqual(
            live.message,
            "Apple Speech isn’t downloaded on this iPhone. Download it in Settings → Speech engines, or switch Live "
                + "text to Parakeet")
    }

    // MARK: - Review M9: the lease is released on every failed path too

    func testAMeetingThatFailsToStartReleasesTheLease() async throws {
        let router = makeRouter(FakeSpeech(id: "fake.a"), FakeSpeech(id: "fake.b"))
        let h = try MeetingHarness(engine: router)
        defer { h.cleanUp() }
        h.recorder.state.withLock { $0.startError = .startFailed("synthetic: no input") }
        h.coordinator.start()
        XCTAssertEqual(router.activeLeaseCount, 1, "taken at once, before the first await")
        await waitUntil { if case .failed = h.coordinator.state { true } else { false } }
        XCTAssertEqual(router.activeLeaseCount, 0)
        XCTAssertNoThrow(try router.select(keyB, for: .final), "the routes are free again")
    }

    func testAMeetingWhoseFinalPassFailsReleasesTheLease() async throws {
        let b = FakeSpeech(id: "fake.b")
        await b.failTranscription(with: SpeechEngineError.underlying("synthetic failure"))
        let router = makeRouter(FakeSpeech(id: "fake.a"), b, final: keyB)
        let h = try MeetingHarness(engine: router)
        defer { h.cleanUp() }
        h.coordinator.start()
        await waitUntil { h.coordinator.state == .recording }
        h.recorder.send(.samples(toneSamples(seconds: 2)))
        await waitUntil { h.coordinator.recordedSeconds >= 2 }
        h.coordinator.stop()
        await waitUntil { if case .failed = h.coordinator.state { true } else { false } }
        guard case .failed(_, let id) = h.coordinator.state else { return XCTFail("expected failed") }
        XCTAssertNotNil(id, "the row and audio are kept for Retry")
        XCTAssertEqual(router.activeLeaseCount, 0)
        XCTAssertNoThrow(try router.select(keyA, for: .final))
    }

    func testADiscardedMeetingReleasesTheLease() async throws {
        let router = makeRouter(FakeSpeech(id: "fake.a"), FakeSpeech(id: "fake.b"))
        let h = try MeetingHarness(engine: router)
        defer { h.cleanUp() }
        h.coordinator.start()
        await waitUntil { h.coordinator.state == .recording }
        XCTAssertEqual(router.activeLeaseCount, 1)
        h.coordinator.discard()
        await h.coordinator.settle()
        XCTAssertEqual(router.activeLeaseCount, 0)
    }
}
