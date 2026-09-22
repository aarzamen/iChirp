import ChirpCore
import ChirpText
import Foundation
import XCTest

@testable import ChirpFeatures

/// M2 Step 4: the dictation coordinator on fakes (no microphone, no model). The rule under test above all others:
/// the copied text is the final pass's output, never the live preview.
@MainActor
final class DictationCoordinatorTests: XCTestCase {
    @MainActor private struct Harness {
        let root: URL
        let paths: AppPaths
        let store = FakeStore()
        let speech: FakeSpeech
        let capture = FakeCapture()
        let live = FakeLiveProvider()
        let clipboard = FakeClipboard()
        let settings: InMemorySettingsStore
        let coordinator: DictationCoordinator
        let states = StateLog()

        init(
            testCase: XCTestCase,
            settings: TranscriptionSettings = Harness.defaultSettings,
            speech: FakeSpeech = FakeSpeech(),
            rules: DictationTextRules = DictationTextRules()
        ) {
            let base = FileManager.default.temporaryDirectory
                .appendingPathComponent("DictationCoordinatorTests-\(UUID().uuidString)", isDirectory: true)
            root = base.appendingPathComponent("iChirp", isDirectory: true)
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            testCase.addTeardownBlock { try? FileManager.default.removeItem(at: base) }
            paths = AppPaths(root: root)
            self.speech = speech
            self.settings = InMemorySettingsStore(settings)
            coordinator = DictationCoordinator(
                capture: capture, speech: speech, liveSessions: live, scheduler: SpeechJobScheduler(), store: store,
                paths: paths, settings: self.settings, clipboard: clipboard, textRules: { rules })
            let states = self.states
            coordinator.onStateChange = { states.append($0) }
        }

        /// Raw clean-up and "Polish after" off, so the copied text is the engine's text as is.
        static var defaultSettings: TranscriptionSettings {
            var value = TranscriptionSettings()
            value.dictationPolishAfter = false
            return value
        }

        var wavURL: URL? { capture.url }

        func startRecording() async {
            coordinator.start()
            await waitUntil {
                coordinator.state == .recording || { if case .failed = coordinator.state { true } else { false } }()
            }
        }

        /// The row the coordinator reported (fails the test when there is none).
        func row(_ id: UUID? = nil) async throws -> Transcription {
            let id = try XCTUnwrap(id ?? coordinator.transcriptionID)
            let row = await store.row(id)
            return try XCTUnwrap(row)
        }

        func stopAndWait() async {
            coordinator.stop()
            await waitUntil { coordinator.state.isFinished }
        }
    }

    @MainActor final class StateLog {
        private(set) var all: [DictationFlowState] = []
        func append(_ state: DictationFlowState) { all.append(state) }
    }

    // MARK: - The copy rule

    func testCopiedTextIsTheFinalPassNotTheLastPartial() async throws {
        let h = Harness(testCase: self)
        await h.startRecording()
        h.capture.send(.samples([Float](repeating: 0.1, count: 16_000)))
        let partial = "Hello their general can of bee"
        h.live.session.publish(partial)
        await waitUntil { !h.coordinator.committedText.isEmpty || !h.coordinator.tentativeText.isEmpty }
        XCTAssertEqual(h.coordinator.committedText + " " + h.coordinator.tentativeText, partial)

        let hold = await h.speech.holdNextTranscription()
        h.coordinator.stop()
        await hold.entered.wait()
        let liveFinished = await h.live.session.finished
        XCTAssertTrue(liveFinished, "the live session is finished before the final pass runs")
        hold.release.fire()
        await waitUntil { h.coordinator.state.isFinished }

        XCTAssertEqual(h.coordinator.state, .done)
        XCTAssertEqual(h.clipboard.copies, [FakeSpeech.helloText])
        XCTAssertNotEqual(h.clipboard.copies.first, partial)
        XCTAssertEqual(h.coordinator.copiedText, FakeSpeech.helloText)
        let options = await h.speech.transcribedOptions
        XCTAssertEqual(options.map(\.purpose), [.dictation])
        let urls = await h.speech.transcribedURLs
        XCTAssertEqual(urls, [h.wavURL], "the final pass reads the recorded WAV")

        let row = try await h.row()
        XCTAssertEqual(row.sourceType, .dictation)
        XCTAssertEqual(row.status, .completed)
        XCTAssertEqual(row.rawTranscript, FakeSpeech.helloText)
        XCTAssertEqual(row.mediaRelativePath, "media/\(row.id.uuidString)/dictation.wav")
        XCTAssertEqual(row.durationMs, FakeCapture.recordedMs)
        XCTAssertEqual(h.states.all, [.starting, .recording, .stopping, .done])
    }

    func testPolishAfterCopiesTheCleanedFinalPassWithCustomWordsAndSnippets() async throws {
        var settings = Harness.defaultSettings
        settings.dictationPolishAfter = true
        let rules = DictationTextRules(
            customWords: [CustomWord(word: "Kenobi", replacement: "Obi-Wan")],
            snippets: [TextSnippet(trigger: "general", expansion: "General")])
        let h = Harness(testCase: self, settings: settings, rules: rules)
        await h.startRecording()
        h.live.session.publish("general can obey")
        await h.stopAndWait()

        let expected = try XCTUnwrap(
            TextRefinement().refine(
                rawText: FakeSpeech.helloText, mode: .clean, customWords: rules.customWords, snippets: rules.snippets))
        XCTAssertTrue(expected.contains("Obi-Wan"), expected)
        XCTAssertEqual(h.clipboard.copies, [expected])
        let row = try await h.row()
        XCTAssertEqual(row.rawTranscript, FakeSpeech.helloText)
        XCTAssertEqual(row.cleanTranscript, expected)
        XCTAssertTrue(h.settings.load().dictationPolishAfter)
    }

    func testPolishAfterIsRememberedInSettings() {
        let h = Harness(testCase: self)
        XCTAssertFalse(h.coordinator.polishAfter)
        h.coordinator.polishAfter = true
        XCTAssertTrue(h.settings.load().dictationPolishAfter)
    }

    // MARK: - Cancel

    func testCancelWhileRecordingLeavesNoRowAndNoAudio() async throws {
        let h = Harness(testCase: self)
        await h.startRecording()
        let folder = try XCTUnwrap(h.wavURL).deletingLastPathComponent()
        XCTAssertTrue(fileExists(folder))

        h.coordinator.cancel()
        await waitUntil { h.coordinator.state == .cancelled }
        await waitUntil { h.coordinator.transcriptionID == nil }
        XCTAssertEqual(h.capture.cancels, 1)
        XCTAssertFalse(fileExists(folder))
        let rows = try await h.store.fetchAll()
        XCTAssertEqual(rows, [])
        XCTAssertEqual(h.clipboard.copies, [])
        let finished = await h.live.session.finished
        XCTAssertTrue(finished)
    }

    func testCancelDuringTheFinalPassDeletesTheRowAndAudioAndCopiesNothing() async throws {
        let h = Harness(testCase: self)
        await h.startRecording()
        let folder = try XCTUnwrap(h.wavURL).deletingLastPathComponent()
        let hold = await h.speech.holdNextTranscription()
        h.coordinator.stop()
        await hold.entered.wait()
        let during = try await h.store.fetchAll()
        XCTAssertEqual(during.map(\.status), [.processing], "the row exists while the final pass runs")

        h.coordinator.cancel()
        await waitUntil { h.coordinator.state == .cancelled }
        await waitUntil { h.coordinator.transcriptionID == nil }
        let rows = try await h.store.fetchAll()
        XCTAssertEqual(rows, [])
        XCTAssertFalse(fileExists(folder))
        XCTAssertEqual(h.clipboard.copies, [])
    }

    // MARK: - Failures keep the audio

    func testFailureKeepsTheAudioAndRetryCopiesTheFinalPass() async throws {
        let h = Harness(testCase: self)
        await h.speech.failTranscription(with: FakeError(message: "The engine stumbled."))
        await h.startRecording()
        await h.stopAndWait()

        XCTAssertEqual(h.coordinator.state, .failed("The engine stumbled."))
        let id = try XCTUnwrap(h.coordinator.transcriptionID)
        let failed = try await h.row(id)
        XCTAssertEqual(failed.status, .failed)
        XCTAssertEqual(failed.errorMessage, "The engine stumbled.")
        XCTAssertTrue(fileExists(try XCTUnwrap(h.wavURL)), "the recording is kept")
        XCTAssertTrue(h.coordinator.canRetry)
        XCTAssertEqual(h.clipboard.copies, [])

        await h.speech.failTranscription(with: nil)
        h.coordinator.retry()
        await waitUntil { h.coordinator.state == .done }
        XCTAssertEqual(h.clipboard.copies, [FakeSpeech.helloText])
        let done = try await h.row(id)
        XCTAssertEqual(done.status, .completed)
        XCTAssertNil(done.errorMessage)
    }

    func testEmptyTranscriptReadsDidntCatchThatAndKeepsTheAudio() async throws {
        let h = Harness(testCase: self)
        await h.speech.failTranscription(with: SpeechEngineError.emptyTranscript)
        await h.startRecording()
        await h.stopAndWait()
        XCTAssertEqual(h.coordinator.state, .failed(DictationFlowStateMachine.noSpeechMessage))
        let row = try await h.row()
        XCTAssertEqual(row.status, .failed)
        XCTAssertTrue(row.errorMessage?.hasPrefix("Didn’t catch that") ?? false)
        XCTAssertTrue(fileExists(try XCTUnwrap(h.wavURL)))
    }

    func testRecordingUnderPointThreeSecondsLeavesNothing() async throws {
        let h = Harness(testCase: self)
        h.capture.failStop(with: .tooShort)
        await h.startRecording()
        let folder = try XCTUnwrap(h.wavURL).deletingLastPathComponent()
        await h.stopAndWait()
        XCTAssertEqual(h.coordinator.state, .failed(AudioCaptureError.tooShort.errorDescription!))
        XCTAssertFalse(h.coordinator.canRetry)
        XCTAssertFalse(fileExists(folder))
        let rows = try await h.store.fetchAll()
        XCTAssertEqual(rows, [])
    }

    func testMissingModelFailsBeforeTheMicrophoneStarts() async throws {
        let h = Harness(testCase: self, speech: FakeSpeech(status: .notDownloaded))
        await h.startRecording()
        XCTAssertEqual(h.coordinator.state, .failed(FileTranscriptionPipeline.modelMissingMessage))
        XCTAssertEqual(h.capture.starts, 0)
    }

    func testDeniedMicrophoneFailsWithTheSettingsHint() async throws {
        let h = Harness(testCase: self)
        h.capture.setPermission(.undetermined, grantOnRequest: false)
        await h.startRecording()
        XCTAssertEqual(h.coordinator.state, .failed(AudioCaptureError.microphonePermissionDenied.errorDescription!))
        XCTAssertEqual(h.capture.starts, 0)
    }

    // MARK: - Interruptions

    func testInterruptionPausesAndAManualResumeContinues() async throws {
        let h = Harness(testCase: self)
        await h.startRecording()
        h.capture.send(.event(.interrupted))
        await waitUntil { h.coordinator.state == .paused(.interrupted) }
        h.capture.send(.event(.waitingForResume))
        await waitUntil { h.coordinator.state == .paused(.waitingForResume) }

        h.coordinator.resume()
        await waitUntil { h.coordinator.state == .recording }
        XCTAssertEqual(h.capture.resumes, 1)
        await h.stopAndWait()
        XCTAssertEqual(h.coordinator.state, .done)
    }

    func testMicrophoneFailureFinishesWithWhatWasRecorded() async throws {
        let h = Harness(testCase: self)
        await h.startRecording()
        h.capture.send(.event(.failed(message: "The microphone stopped.")))
        await waitUntil { h.coordinator.state.isFinished }
        XCTAssertEqual(h.coordinator.state, .done)
        XCTAssertEqual(h.clipboard.copies, [FakeSpeech.helloText])
        XCTAssertEqual(h.capture.stops, 1)
    }

    // MARK: - Settings and display

    func testKeepAudioOffDeletesTheRecordingAfterASuccessfulPass() async throws {
        var settings = Harness.defaultSettings
        settings.keepDictationAudio = false
        let h = Harness(testCase: self, settings: settings)
        await h.startRecording()
        let wav = try XCTUnwrap(h.wavURL)
        await h.stopAndWait()
        XCTAssertEqual(h.coordinator.state, .done)
        XCTAssertFalse(fileExists(wav))
        let row = try await h.row()
        XCTAssertNil(row.mediaRelativePath)
        XCTAssertEqual(row.rawTranscript, FakeSpeech.helloText)
    }

    func testTimerLevelsAndLiveSamplesComeFromTheRecording() async throws {
        let h = Harness(testCase: self)
        await h.startRecording()
        h.capture.send(.samples([Float](repeating: 0, count: 24_000)))
        h.capture.send(.level(0.5))
        await waitUntil { h.coordinator.recordedSeconds >= 1.5 && h.coordinator.levels == [0.5] }
        let appended = await h.live.session.appendedSamples
        XCTAssertEqual(appended, 24_000)
        XCTAssertEqual(h.coordinator.elapsedLabelSeconds, 1)
        await h.stopAndWait()
    }

    func testStartWhileTheFinalPassRunsShowsBusyAndCancelsNothing() async throws {
        let h = Harness(testCase: self)
        await h.startRecording()
        let hold = await h.speech.holdNextTranscription()
        h.coordinator.stop()
        await hold.entered.wait()
        h.coordinator.start()
        XCTAssertTrue(h.coordinator.isBusyNoticeVisible)
        XCTAssertEqual(h.coordinator.state, .stopping)
        hold.release.fire()
        await waitUntil { h.coordinator.state == .done }
        XCTAssertEqual(h.capture.starts, 1)
    }

    func testToggleStartsWhenIdleAndStopsWhenRecording() async throws {
        let h = Harness(testCase: self)
        h.coordinator.toggle()
        await waitUntil { h.coordinator.state == .recording }
        h.coordinator.toggle()
        await waitUntil { h.coordinator.state == .done }
        XCTAssertEqual(h.clipboard.copies, [FakeSpeech.helloText])
    }

    func testLibraryRetryOfAFailedDictationTranscribesWithoutCopying() async throws {
        let h = Harness(testCase: self)
        await h.speech.failTranscription(with: FakeError(message: "Nope."))
        await h.startRecording()
        await h.stopAndWait()
        let id = try XCTUnwrap(h.coordinator.transcriptionID)
        h.coordinator.dismiss()

        await h.speech.failTranscription(with: nil)
        let saved = await h.coordinator.retry(transcriptionID: id)
        XCTAssertEqual(saved?.status, .completed)
        XCTAssertEqual(h.clipboard.copies, [], "a Library retry does not touch the clipboard")
        XCTAssertEqual(h.coordinator.state, .idle)
    }

    // MARK: - Launch recovery

    func testLaunchAdoptsARecordingLeftWithoutARowAndDeletesNothing() async throws {
        let h = Harness(testCase: self)
        let orphan = UUID()
        let folder = h.paths.mediaDirectory(for: orphan)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let wav = folder.appendingPathComponent("dictation.wav")
        try Data(repeating: 3, count: 128).write(to: wav)
        // A file import's folder (no dictation.wav) and a known row's recording are left alone.
        let other = h.paths.mediaDirectory(for: UUID())
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 8).write(to: other.appendingPathComponent("source.m4a"))

        let added = await h.coordinator.recoverOrphanedRecordings()
        XCTAssertEqual(added, 1)
        let row = try await h.row(orphan)
        XCTAssertEqual(row.sourceType, .dictation)
        XCTAssertEqual(row.status, .interrupted)
        XCTAssertEqual(row.mediaRelativePath, "media/\(orphan.uuidString)/dictation.wav")
        XCTAssertTrue(fileExists(wav))
        let again = await h.coordinator.recoverOrphanedRecordings()
        XCTAssertEqual(again, 0, "an adopted recording is not adopted twice")

        let retried = await h.coordinator.retry(transcriptionID: orphan)
        XCTAssertEqual(retried?.status, .completed)
    }
}
