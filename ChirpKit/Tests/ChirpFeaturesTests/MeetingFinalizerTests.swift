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

    // MARK: - Learned rules (plan 025 B4)

    func testLearnedRulesAreCorrectionsNotTokenRewrites() async throws {
        let rule = CustomWord(word: "kenobi", replacement: "Kenobee", source: .learned)
        let h = try MeetingHarness(learnedRules: [rule])
        harness = h
        await h.speech.setTranscript(text: "um Hello there. General Kenobi.", words: FakeSpeech.helloWords)
        let id = try await insertStoppedMeeting(h)

        let saved = await h.finalizer.finalize(id: id)

        XCTAssertEqual(saved?.status, .completed)
        XCTAssertEqual(saved?.rawTranscript, "um Hello there. General Kenobi.", "the words as heard are kept")
        XCTAssertEqual(saved?.wordTimestamps?.map(\.word), FakeSpeech.helloWords.map(\.word))
        XCTAssertEqual(saved?.textCorrections?.items.map(\.origin), [.rule])
        XCTAssertEqual(saved?.textCorrections?.items.map(\.text), ["Kenobee."])
        XCTAssertEqual(saved?.text(.heard).lines.last?.text.hasSuffix("General Kenobee."), true)
        XCTAssertFalse(h.lockStore.hasLockFile(sessionId: id))
    }

    func testManualWordsStillRewriteMeetingTokens() async throws {
        let h = try MeetingHarness(customWords: [CustomWord(word: "kenobi", replacement: "Kenobee")])
        harness = h
        await h.speech.setTranscript(text: "um Hello there. General Kenobi.", words: FakeSpeech.helloWords)
        let id = try await insertStoppedMeeting(h)

        let saved = await h.finalizer.finalize(id: id)

        XCTAssertEqual(saved?.rawTranscript, "um Hello there. General Kenobee.")
        XCTAssertEqual(saved?.wordTimestamps?.last?.word, "Kenobee.")
        XCTAssertNil(saved?.textCorrections, "manual words are no corrections")
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

    /// Review R5-5: a normalization that fails on a recording that has audio (a full disk while preparing a long
    /// meeting, a decode error after a crash) says the recording is saved and what failed, never "No audio was saved".
    func testANormalizationFailureOnARecordingWithAudioSaysWhatFailed() async throws {
        let h = try MeetingHarness()
        harness = h
        await h.normalizer.failNormalize(with: FakeError(message: "Could not write decoded audio: no space"))
        let id = try await insertStoppedMeeting(h)
        let saved = await h.finalizer.finalize(id: id)

        XCTAssertEqual(saved?.status, .failed)
        let message = try XCTUnwrap(saved?.errorMessage)
        XCTAssertFalse(message.contains("No audio"), message)
        XCTAssertTrue(message.hasPrefix("The recording is saved"), message)
        XCTAssertTrue(message.contains("Could not write decoded audio: no space"), message)
        XCTAssertTrue(message.contains("Retry"), message)
        XCTAssertTrue(fileExists(h.audio(id)))
        XCTAssertTrue(h.lockStore.hasLockFile(sessionId: id))
    }

    /// A recording killed in its first moment holds a header and no samples: that, and only that, is "No audio".
    func testARecordingWithNoAudioStillSaysNoAudio() async throws {
        let h = try MeetingHarness()
        harness = h
        await h.normalizer.failNormalize(with: FakeError(message: "The operation could not be completed"))
        await h.normalizer.reportDuration(0)
        let id = try await insertStoppedMeeting(h)
        let saved = await h.finalizer.finalize(id: id)
        XCTAssertEqual(saved?.errorMessage, MeetingFinalizer.FinalizeError.noAudio.errorDescription)
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
