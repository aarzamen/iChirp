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
