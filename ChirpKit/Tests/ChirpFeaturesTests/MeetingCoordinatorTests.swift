import ChirpCore
import XCTest

@testable import ChirpFeatures

/// M3 Steps 2 and 5: the meeting flow with a fake recorder, fake engines and a real lock store on disk.
@MainActor
final class MeetingCoordinatorTests: XCTestCase {
    private var harness: MeetingHarness!

    override func tearDown() async throws {
        harness?.cleanUp()
        harness = nil
    }

    private func startRecording(_ h: MeetingHarness) async throws -> UUID {
        h.coordinator.start()
        await waitUntil {
            h.coordinator.state == .recording || !h.coordinator.state.isCapturing && h.coordinator.state != .starting
        }
        XCTAssertEqual(h.coordinator.state, .recording)
        return try XCTUnwrap(h.coordinator.sessionID)
    }

    func testLockIsWrittenBeforeTheFirstAudioBuffer() async throws {
        let h = try MeetingHarness()
        harness = h
        let id = try await startRecording(h)
        XCTAssertEqual(h.recorder.state.withLock { $0.lockExistedAtStart }, true)
        let lock = try XCTUnwrap(h.lockStore.read(sessionId: id))
        XCTAssertEqual(lock.state, .recording)
        XCTAssertEqual(lock.launchId, h.lockStore.launchId)
        XCTAssertEqual(lock.speechEngine, "fake.parakeet")
        XCTAssertEqual(h.recorder.state.withLock { $0.url }, h.audio(id))
        h.coordinator.discard()
        await h.coordinator.settle()
    }

    func testStopClosesTheAudioSavesTheCompletedMeetingThenRemovesTheLock() async throws {
        let h = try MeetingHarness()
        harness = h
        let id = try await startRecording(h)
        h.recorder.send(.samples(toneSamples(seconds: 2)))
        h.coordinator.notes = "Decide the budget"
        await waitUntil { h.coordinator.recordedSeconds >= 2 }
        h.coordinator.stop()
        await waitUntil { if case .saved = h.coordinator.state { true } else { false } }

        XCTAssertEqual(h.coordinator.state, .saved(id))
        XCTAssertEqual(h.recorder.state.withLock { $0.stopCalls }, 1)
        let rowFetched = try await h.store.fetch(id: id)
        let row = try XCTUnwrap(rowFetched)
        XCTAssertEqual(row.sourceType, .meeting)
        XCTAssertEqual(row.status, .completed)
        XCTAssertEqual(row.userNotes, "Decide the budget")
        XCTAssertEqual(row.mediaRelativePath, "media/\(id.uuidString)/meeting.caf")
        XCTAssertEqual(row.rawTranscript, FakeSpeech.helloText)
        XCTAssertNil(row.cleanTranscript, "meetings skip the Clean pipeline")
        XCTAssertEqual(row.speakerCount, 2, "diarized in the final pass")
        XCTAssertFalse(row.isPartialAudio)
        XCTAssertFalse(h.lockStore.hasLockFile(sessionId: id), "the lock goes only after the completed save")
        XCTAssertTrue(fileExists(h.audio(id)), "the recording is kept")
        XCTAssertFalse(fileExists(h.folder(id).appendingPathComponent("normalized-16k.wav")))
    }

    func testNotesAreSavedIntoTheLockWhileRecording() async throws {
        let h = try MeetingHarness()
        harness = h
        let id = try await startRecording(h)
        h.coordinator.notes = "Action: send the minutes"
        h.coordinator.saveNotesToLock()
        XCTAssertEqual(h.lockStore.read(sessionId: id)?.notes, "Action: send the minutes")
        XCTAssertEqual(h.lockStore.read(sessionId: id)?.state, .recording)
        h.coordinator.discard()
        await h.coordinator.settle()
    }

    /// A slow pause must not let a later resume overtake it: the recorder would end paused while the screen says
    /// Recording (lost audio). Commands reach the recorder in the order the person gave them.
    func testRecorderCommandsKeepTheirOrderWhenOneIsSlow() async throws {
        let h = try MeetingHarness()
        harness = h
        _ = try await startRecording(h)
        let recorder = h.recorder
        recorder.state.withLock { $0.holdNextPause = true }
        h.coordinator.pause()
        await spinUntil { recorder.isHoldingPause }
        h.coordinator.resume()
        h.coordinator.toggleMute()
        // Give an out-of-order resume/mute every chance to overtake the held pause.
        for _ in 0..<1_000 { await Task.yield() }
        XCTAssertEqual(recorder.state.withLock { $0.paused }, [], "nothing may overtake the held pause")
        recorder.releaseHeldPause()
        await spinUntil { recorder.state.withLock { $0.paused == [true, false] && $0.muted == [true] } }
        XCTAssertEqual(h.coordinator.state, .recording)
        h.coordinator.discard()
        await h.coordinator.settle()
    }

    func testPauseMuteAndInterruptionsReachTheRecorderAndDriveTheState() async throws {
        let h = try MeetingHarness()
        harness = h
        _ = try await startRecording(h)
        h.coordinator.pause()
        XCTAssertEqual(h.coordinator.state, .paused)
        h.coordinator.resume()
        XCTAssertEqual(h.coordinator.state, .recording)
        h.coordinator.toggleMute()
        XCTAssertTrue(h.coordinator.isMuted)
        let recorder = h.recorder
        await spinUntil { recorder.state.withLock { $0.paused == [true, false] && $0.muted == [true] } }

        h.recorder.send(.event(.interrupted))
        await waitUntil { h.coordinator.state == .interrupted }
        h.recorder.send(.event(.waitingForResume))
        await waitUntil { h.coordinator.state == .waitingForResume }
        h.coordinator.resume()
        await waitUntil { h.coordinator.state == .recording }
        await spinUntil { recorder.state.withLock { $0.resumeCalls == 1 } }

        h.recorder.send(.event(.failed(message: "Microphone gone")))
        await waitUntil { h.coordinator.state == .waitingForResume }
        XCTAssertEqual(h.coordinator.captureProblem, "Microphone gone")
        h.coordinator.discard()
        await h.coordinator.settle()
    }

    func testAFailedFinalPassKeepsRowLockAndAudioAndRetrySucceeds() async throws {
        let h = try MeetingHarness()
        harness = h
        await h.speech.failTranscription(with: FakeError(message: "engine exploded"))
        let id = try await startRecording(h)
        h.recorder.send(.samples(toneSamples(seconds: 1)))
        await waitUntil { h.coordinator.recordedSeconds >= 1 }
        h.coordinator.stop()
        await waitUntil { if case .failed = h.coordinator.state { true } else { false } }

        XCTAssertEqual(h.coordinator.state, .failed(message: "engine exploded", transcriptionID: id))
        let failedFetched = try await h.store.fetch(id: id)
        let failed = try XCTUnwrap(failedFetched)
        XCTAssertEqual(failed.status, .failed)
        XCTAssertEqual(h.lockStore.read(sessionId: id)?.state, .awaitingTranscription)
        XCTAssertTrue(fileExists(h.audio(id)))

        await h.speech.failTranscription(with: nil)
        h.coordinator.retry()
        await waitUntil { h.coordinator.state == .saved(id) }
        let savedFetched = try await h.store.fetch(id: id)
        let saved = try XCTUnwrap(savedFetched)
        XCTAssertEqual(saved.status, .completed)
        XCTAssertFalse(h.lockStore.hasLockFile(sessionId: id))
    }

    func testDiscardDeletesTheFolderOnlyWhenCalled() async throws {
        let h = try MeetingHarness()
        harness = h
        let id = try await startRecording(h)
        h.recorder.send(.samples(toneSamples(seconds: 1)))
        await waitUntil { h.coordinator.recordedSeconds >= 1 }
        XCTAssertTrue(fileExists(h.audio(id)))
        h.coordinator.discard()
        await h.coordinator.settle()
        XCTAssertEqual(h.coordinator.state, .idle)
        XCTAssertEqual(h.recorder.state.withLock { $0.cancelCalls }, 1)
        XCTAssertFalse(fileExists(h.folder(id)))
        let row = try await h.store.fetch(id: id)
        XCTAssertNil(row)
    }

    func testAFailedStartLeavesNoFolderAndStorageTooLowRefusesToStart() async throws {
        let h = try MeetingHarness()
        harness = h
        h.recorder.state.withLock { $0.startError = .startFailed("no input") }
        h.coordinator.start()
        await waitUntil { if case .failed = h.coordinator.state { true } else { false } }
        let media = h.root.appendingPathComponent("media")
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: media.path)) ?? [], [])

        let full = try MeetingHarness(freeBytes: 100_000_000)
        defer { full.cleanUp() }
        full.coordinator.start()
        await waitUntil { if case .failed = full.coordinator.state { true } else { false } }
        XCTAssertNil(full.recorder.state.withLock { $0.url }, "nothing recorded without storage")
    }

    func testARecordingUnderPointThreeSecondsIsRemoved() async throws {
        let h = try MeetingHarness()
        harness = h
        let id = try await startRecording(h)
        h.recorder.send(.samples([Float](repeating: 0.2, count: 1_000)))
        h.coordinator.stop()
        await waitUntil { if case .failed = h.coordinator.state { true } else { false } }
        XCTAssertFalse(fileExists(h.folder(id)))
        let row = try await h.store.fetch(id: id)
        XCTAssertNil(row)
    }

    func testLivePreviewUsesVoiceActivityWhenItsModelIsOnDiskAndShowsText() async throws {
        let withVAD = try MeetingHarness(
            voiceActivity: FakeVoiceActivity(
                stream: FakeVoiceActivityStream(events: [1: .speechStart, 10: .speechEnd(sampleIndex: 40_960)])))
        harness = withVAD
        _ = try await startRecording(withVAD)
        XCTAssertTrue(withVAD.coordinator.hasLivePreview)
        XCTAssertTrue(withVAD.coordinator.usesVoiceActivity)
        withVAD.recorder.send(.samples(toneSamples(seconds: 3)))
        await waitUntil { !withVAD.coordinator.liveParagraphs.isEmpty }
        XCTAssertEqual(withVAD.coordinator.liveParagraphs.first?.text, FakeSpeech.helloText)
        withVAD.coordinator.discard()
        await withVAD.coordinator.settle()

        let fixed = try MeetingHarness(voiceActivity: FakeVoiceActivity(stream: nil))
        defer { fixed.cleanUp() }
        _ = try await startRecording(fixed)
        XCTAssertTrue(fixed.coordinator.hasLivePreview)
        XCTAssertFalse(fixed.coordinator.usesVoiceActivity, "no VAD model on disk: fixed 5 s chunks")
        fixed.coordinator.discard()
        await fixed.coordinator.settle()

        let noModel = try MeetingHarness(speech: FakeSpeech(status: .notDownloaded))
        defer { noModel.cleanUp() }
        _ = try await startRecording(noModel)
        XCTAssertFalse(noModel.coordinator.hasLivePreview, "records without the model; no live text")
        noModel.coordinator.discard()
        await noModel.coordinator.settle()
    }

    // MARK: - Review N6: the "no live text" message names the live route's own engine

    func testNoLiveTextNamesTheLiveRoutesEngineNotParakeet() async throws {
        let liveKey = SpeechEngineVariantKey(engineID: "fake.whisper")
        let finalKey = SpeechEngineVariantKey(engineID: "fake.final")
        let live = FakeSpeech(status: .notDownloaded, id: "fake.whisper", displayName: "Whisper Base")
        let final = FakeSpeech(id: "fake.final", displayName: "Final Engine")
        let router = SpeechEngineRouter(
            engines: [.init(key: liveKey, engine: live), .init(key: finalKey, engine: final)],
            selection: SpeechRouteSelection(live: liveKey, final: finalKey))
        let h = try MeetingHarness(engine: router)
        harness = h
        _ = try await startRecording(h)

        XCTAssertFalse(h.coordinator.hasLivePreview, "Whisper Base's model is missing")
        let engine = h.coordinator.liveSpeechEngine
        XCTAssertEqual(engine.name, "Whisper Base")
        XCTAssertFalse(engine.isParakeet)

        h.coordinator.discard()
        await h.coordinator.settle()
    }
}
