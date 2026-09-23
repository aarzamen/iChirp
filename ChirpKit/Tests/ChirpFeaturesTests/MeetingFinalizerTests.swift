import ChirpCore
import ChirpText
import XCTest

@testable import ChirpFeatures

/// M3 Step 5: the meeting final pass (custom words only, privacy routing, non-fatal diarization, settlement).
@MainActor
final class MeetingFinalizerTests: XCTestCase {
    private var harness: MeetingHarness!

    override func tearDown() async throws {
        harness?.cleanUp()
        harness = nil
    }

    private func insertStoppedMeeting(_ h: MeetingHarness, privacy: PrivacyClass = .personal) async throws -> UUID {
        let id = try h.makeOrphan(state: .awaitingTranscription)
        try await h.store.insert(
            Transcription(
                id: id, sourceType: .meeting, fileName: "Meeting",
                mediaRelativePath: "media/\(id.uuidString)/meeting.caf", status: .processing, privacyClass: privacy))
        return id
    }

    func testOnlyTheCustomWordStepRunsOnMeetingsWithTimingsAndSpeakersKept() async throws {
        let words = [CustomWord(word: "kenobi", replacement: "Kenobee")]
        let h = try MeetingHarness(customWords: words)
        harness = h
        var settings = h.settings.load()
        settings.cleanupMode = .clean  // Clean mode does not apply to meetings.
        h.settings.save(settings)
        await h.speech.setTranscript(text: "um Hello there. General Kenobi.", words: FakeSpeech.helloWords)
        let id = try await insertStoppedMeeting(h)

        let saved = await h.finalizer.finalize(id: id)

        XCTAssertEqual(saved?.rawTranscript, "um Hello there. General Kenobee.", "fillers stay: verbatim record")
        XCTAssertNil(saved?.cleanTranscript)
        XCTAssertEqual(saved?.wordTimestamps?.last?.word, "Kenobee.")
        XCTAssertEqual(saved?.wordTimestamps?.map(\.startMs), FakeSpeech.helloWords.map(\.startMs))
        XCTAssertNotNil(saved?.wordTimestamps?.first?.speakerId)
        XCTAssertEqual(saved?.transcriptSegments?.isEmpty, false)
        XCTAssertFalse(h.lockStore.hasLockFile(sessionId: id))
        XCTAssertEqual(h.progress.progress(for: id).last?.stage, .finishing)
    }

    func testPrivacyRoutingRefusesACloudEngineForClinicalMeetingsAndKeepsEverything() async throws {
        let h = try MeetingHarness(speech: FakeSpeech(locality: .cloud))
        harness = h
        let id = try await insertStoppedMeeting(h, privacy: .clinical)
        let saved = await h.finalizer.finalize(id: id)
        XCTAssertEqual(saved?.status, .failed)
        let calls = await h.speech.transcribeCalls
        XCTAssertEqual(calls, 0, "no audio reached the refused engine")
        XCTAssertTrue(h.lockStore.hasLockFile(sessionId: id))
        XCTAssertTrue(fileExists(h.audio(id)))
    }

    func testDiarizationFailureIsNotFatal() async throws {
        let h = try MeetingHarness()
        harness = h
        await h.diarizer.failDiarization(with: FakeError(message: "no speakers"))
        let id = try await insertStoppedMeeting(h)
        let saved = await h.finalizer.finalize(id: id)
        XCTAssertEqual(saved?.status, .completed)
        XCTAssertNil(saved?.speakers)
    }

    // MARK: - Review N4: a model this pass holds past a route change is released once it ends

    /// `MeetingRecoveryService` runs `finalize` with no lease at all (the coordinator that would hold one never
    /// started this launch), so a route change can reach the router while this pass still holds its engine.
    func testAModelThisPassHoldsPastARouteChangeIsReleasedWhenItEnds() async throws {
        let keyA = SpeechEngineVariantKey(engineID: "fake.a")
        let keyB = SpeechEngineVariantKey(engineID: "fake.b")
        let a = FakeSpeech(id: "fake.a")
        let b = FakeSpeech(id: "fake.b")
        let router = SpeechEngineRouter(
            engines: [.init(key: keyA, engine: a), .init(key: keyB, engine: b)],
            selection: SpeechRouteSelection(live: keyB, final: keyA))
        let h = try MeetingHarness(engine: router)
        harness = h
        let id = try await insertStoppedMeeting(h)
        let hold = await a.holdNextTranscription()

        let pass = Task { await h.finalizer.finalize(id: id) }
        await hold.entered.wait()
        try router.select(keyB, for: .final)
        var unloads = await a.unloadCalls
        XCTAssertEqual(unloads, 0, "busy: refused while this pass still holds it")

        hold.release.fire()
        _ = await pass.value

        unloads = await a.unloadCalls
        XCTAssertEqual(unloads, 1, "the finalizer retries the release once its pass ends")
    }

    func testANonMeetingOrNonProcessingRowIsLeftAlone() async throws {
        let h = try MeetingHarness()
        harness = h
        let file = Transcription(fileName: "memo.m4a", status: .processing)
        try await h.store.insert(file)
        let notMeeting = await h.finalizer.finalize(id: file.id)
        XCTAssertNil(notMeeting)
        let id = try await insertStoppedMeeting(h)
        _ = try await h.store.transitionStatus(id: id, from: [.processing], to: .failed, errorMessage: "x")
        let untouched = await h.finalizer.finalize(id: id)
        XCTAssertEqual(untouched?.status, .failed)
        let calls = await h.speech.transcribeCalls
        XCTAssertEqual(calls, 0)
    }
}
