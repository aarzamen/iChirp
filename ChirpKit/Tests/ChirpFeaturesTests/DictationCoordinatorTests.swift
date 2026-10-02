import AVFoundation
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
            rules: DictationTextRules = DictationTextRules(),
            voiceCommands: DictationVoiceCommands? = nil
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
                paths: paths, settings: self.settings, clipboard: clipboard, textRules: { rules },
                voiceCommands: voiceCommands)
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

    /// M6 (plan 015 Step 7): the copy rule with voice commands on. The live preview says "new paragraph" (a chip
    /// only); the copied text is the final pass with its whole-sentence commands applied, and nothing else.
    func testCopiedTextIsTheFinalPassWithVoiceCommandsAppliedNeverTheLivePreview() async throws {
        let commands = Self.voiceCommands(enabled: true)
        let speech = FakeSpeech()
        let finalPass =
            "Patient seen today. New paragraph. Start a new paragraph of treatment. Scratch that. Plan follows."
        await speech.setTranscript(text: finalPass, words: FakeSpeech.helloWords)
        let h = Harness(testCase: self, speech: speech, voiceCommands: commands)
        await h.startRecording()
        h.capture.send(.samples([Float](repeating: 0.1, count: 16_000)))
        let partial = "Patient seen today. New paragraph"
        h.live.session.publish(partial)
        await waitUntil { commands.chip != nil }
        XCTAssertEqual(commands.chip?.command, "new_paragraph")
        XCTAssertEqual(commands.chip?.isStub, true, "the STUB is labelled as such")
        XCTAssertEqual(h.coordinator.committedText + " " + h.coordinator.tentativeText, partial, "the chip never edits")

        await h.stopAndWait()
        XCTAssertEqual(h.coordinator.state, .done)
        let expected = await VoiceCommandResolver(engine: StubStructureModel(), gate: StructuredResultGate())
            .resolve(finalPass).text
        XCTAssertEqual(expected, "Patient seen today.\n\nPlan follows.")
        XCTAssertEqual(h.clipboard.copies, [expected], "copied = final pass with commands applied")
        XCTAssertEqual(h.coordinator.copiedText, expected)
        let row = try await h.row()
        XCTAssertEqual(row.rawTranscript, finalPass, "the saved transcript keeps every word")
    }

    /// Review R5-2 (plan 025 ruling 2): the applied voice commands are stored as `voiceCommand` corrections before the
    /// SOAP hand-off opens, so the SOAP note's model input reads what was copied: a scratched order never reaches it.
    func testAScratchedOrderNeverReachesTheSOAPModelInput() async throws {
        for polish in [false, true] {
            let commands = Self.voiceCommands(enabled: true)
            let speech = FakeSpeech()
            let finalPass = "Patient seen today. Take aspirin 81 mg. Scratch that. Recheck in two weeks. Send to SOAP."
            let words = finalPass.split(separator: " ").enumerated().map { index, word in
                WordTimestamp(word: String(word), startMs: index * 300, endMs: index * 300 + 250, confidence: 0.9)
            }
            await speech.setTranscript(text: finalPass, words: words)
            var settings = Harness.defaultSettings
            settings.dictationPolishAfter = polish
            let h = Harness(testCase: self, settings: settings, speech: speech, voiceCommands: commands)
            await h.startRecording()
            h.capture.send(.samples([Float](repeating: 0.1, count: 16_000)))
            await h.stopAndWait()

            let copied = "Patient seen today. Recheck in two weeks."
            XCTAssertEqual(h.clipboard.copies, [copied], "polish \(polish)")
            XCTAssertEqual(commands.pendingTransform?.target, .soap)
            let row = try await h.row()
            XCTAssertEqual(row.rawTranscript, finalPass, "the words as heard are kept")
            XCTAssertEqual(row.wordTimestamps, words)
            let items = try XCTUnwrap(row.textCorrections?.items)
            XCTAssertFalse(items.isEmpty)
            XCTAssertEqual(Set(items.map(\.origin)), [.voiceCommand])
            XCTAssertEqual(Set(items.map(\.batchID)).count, 1, "one dictation's commands are one batch")
            XCTAssertEqual(row.plainText(.shown(.raw)), copied)
            XCTAssertFalse(row.derivedTitle?.contains("aspirin") ?? true)

            // The SOAP run reads the stored row.
            let deliverables = FakeDeliverableStore()
            try await deliverables.installBuiltInTemplates(BuiltInTemplates.all)
            let service = DeliverableService(
                transcripts: h.store, deliverables: deliverables, routingPolicy: { PrivacyRoutingPolicy() })
            let model = Destination.onDevice.makeModel()
            model.script([.text("S: Synthetic.")])
            for try await _ in service.generate(
                templateID: BuiltInTemplates.soapNote.id, transcriptionID: row.id, model: model)
            {}
            XCTAssertTrue(model.everythingReceived.contains("Recheck in two weeks."), "polish \(polish)")
            XCTAssertFalse(model.everythingReceived.contains("aspirin"), "polish \(polish): the scratched order")
            XCTAssertFalse(model.everythingReceived.localizedCaseInsensitiveContains("scratch that"))
        }
    }

    /// Plan 025 fix round 1: one dictation with voice commands on, its words matching the final pass.
    private func dictate(
        _ finalPass: String, words matching: Bool = true, prepare: (FakeStore) async -> Void = { _ in }
    ) async throws -> (Harness, DictationVoiceCommands) {
        let commands = Self.voiceCommands(enabled: true)
        let speech = FakeSpeech()
        let words = finalPass.split(separator: " ").enumerated().map { index, word in
            WordTimestamp(word: String(word), startMs: index * 300, endMs: index * 300 + 250, confidence: 0.9)
        }
        await speech.setTranscript(text: finalPass, words: matching ? words : [])
        let h = Harness(testCase: self, speech: speech, voiceCommands: commands)
        await prepare(h.store)
        await h.startRecording()
        h.capture.send(.samples([Float](repeating: 0.1, count: 16_000)))
        await h.stopAndWait()
        return (h, commands)
    }

    /// Fix round 1 (review IMPORTANT 1): when the commands cannot be stored, Send to SOAP is not opened and the Done
    /// screen says so in place of "Voice commands applied": the transcript still has every word.
    func testCommandsThatCannotBeStoredSayYourTranscriptKeepsEveryWordAndOpenNoSOAP() async throws {
        let finalPass = "Patient seen today. Take aspirin 81 mg. Scratch that. Send to SOAP."
        for failure in ["no word timings", "a refused write"] {
            let (h, commands) = try await dictate(finalPass, words: failure != "no word timings") { store in
                if failure == "a refused write" {
                    await store.failNextTextCorrectionWrite(with: FakeError(message: "synthetic write failure"))
                }
            }
            XCTAssertEqual(h.clipboard.copies, ["Patient seen today."], failure)
            XCTAssertNil(commands.pendingTransform, "\(failure): no SOAP from text that still has the scratched order")
            XCTAssertEqual(h.coordinator.voiceCommandsNotSaved, .notSaved(droppedSendOn: [.sendToSOAP]), failure)
            XCTAssertEqual(
                h.coordinator.voiceCommandsNotSaved?.message,
                "Your voice commands couldn’t be saved to the transcript; it still has every word. "
                    + "Send to SOAP was not opened.")
            let row = try await h.row()
            XCTAssertNil(row.textCorrections, failure)
            XCTAssertEqual(row.rawTranscript, finalPass)
        }
    }

    /// Fix round 1: a dictation whose every sentence was scratched copies nothing, stores nothing (a correction cannot
    /// be empty), keeps the words as heard, opens no SOAP and says so.
    func testAFullyScratchedDictationSaysNothingWasSentAndKeepsTheHeardWords() async throws {
        let finalPass = "Take aspirin 81 mg. Scratch that. Send to SOAP."
        let (h, commands) = try await dictate(finalPass)
        XCTAssertEqual(h.coordinator.copiedText, "")
        XCTAssertNil(commands.pendingTransform)
        XCTAssertEqual(h.coordinator.voiceCommandsNotSaved, .everythingScratched(droppedSendOn: [.sendToSOAP]))
        XCTAssertEqual(
            h.coordinator.voiceCommandsNotSaved?.message,
            "Everything was scratched, so nothing was copied or sent. The transcript keeps every word you said. "
                + "Send to SOAP was not opened.")
        let row = try await h.row()
        XCTAssertNil(row.textCorrections)
        XCTAssertEqual(row.rawTranscript, finalPass)
        // The next dictation starts without the notice.
        await h.startRecording()
        XCTAssertNil(h.coordinator.voiceCommandsNotSaved)
        await h.stopAndWait()
    }

    func testStoredCommandsLeaveNoNotice() async throws {
        let (h, commands) = try await dictate("Patient seen today. Take aspirin 81 mg. Scratch that. Send to SOAP.")
        XCTAssertNil(h.coordinator.voiceCommandsNotSaved)
        XCTAssertEqual(commands.pendingTransform?.target, .soap)
    }

    /// Review R5-17 (and L3 minor 6): a "stop" heard in the live preview is a chip only. The dictation keeps
    /// recording, so nothing said after a misheard "stop" is lost.
    func testALiveStopIsAChipAndTheDictationKeepsRecording() async throws {
        let commands = Self.voiceCommands(enabled: true)
        let h = Harness(testCase: self, voiceCommands: commands)
        await h.startRecording()
        h.live.session.publish("Patient is well. Stop dictation")
        await waitUntil { commands.chip != nil }
        XCTAssertEqual(commands.chip?.command, "stop")
        XCTAssertEqual(h.coordinator.state, .recording)
        XCTAssertEqual(h.capture.stops, 0)
        await h.stopAndWait()
    }

    func testVoiceCommandsOffLeaveTheFinalPassUntouched() async throws {
        let speech = FakeSpeech()
        await speech.setTranscript(text: "One. New paragraph. Two.", words: FakeSpeech.helloWords)
        let h = Harness(testCase: self, speech: speech, voiceCommands: Self.voiceCommands(enabled: false))
        await h.startRecording()
        h.capture.send(.samples([Float](repeating: 0.1, count: 16_000)))
        await h.stopAndWait()
        XCTAssertEqual(h.clipboard.copies, ["One. New paragraph. Two."])
    }

    static func voiceCommands(enabled: Bool) -> DictationVoiceCommands {
        var settings = StructureSettings()
        settings.voiceCommandsEnabled = enabled
        settings.engine = .stub
        return DictationVoiceCommands(
            settings: InMemoryStructureSettingsStore(settings),
            engines: StructureEngines(needle: nil, needleAvailability: { .unavailable("test") }), pauseSeconds: 0.05)
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

    /// Review R2-6: a recording that stopped on its own (a full disk, a microphone that could not restart) says why
    /// next to its outcome, so a shortened dictation is never copied without a word; the next dictation starts clean.
    func testARecordingThatStoppedOnItsOwnSaysWhyWithTheOutcome() async throws {
        let h = Harness(testCase: self)
        await h.startRecording()
        let reason = "Parakeet could not save more audio (the iPhone may be out of storage)."
        h.capture.send(.event(.failed(message: reason)))
        await waitUntil { h.coordinator.state.isFinished }
        XCTAssertEqual(h.coordinator.state, .done)
        XCTAssertEqual(h.coordinator.captureNotice, reason)
        XCTAssertEqual(h.clipboard.copies, [FakeSpeech.helloText], "what was saved is still transcribed and copied")

        h.coordinator.dismiss()
        await h.startRecording()
        XCTAssertNil(h.coordinator.captureNotice)
        await h.stopAndWait()
        XCTAssertNil(h.coordinator.captureNotice, "an ordinary stop says nothing extra")
    }

    /// Review R5-10: a call that takes the microphone while the start still finishes (the live preview is being set
    /// up) pauses the dictation; it is never dropped, so the screen never says Recording while the call has the
    /// microphone.
    func testAnInterruptionWhileTheStartFinishesPausesTheDictation() async throws {
        let h = Harness(testCase: self)
        let hold = h.live.holdNextSession()
        h.coordinator.start()
        await hold.entered.wait()
        XCTAssertEqual(h.coordinator.state, .starting)
        h.capture.send(.event(.interrupted))
        h.capture.send(.samples([Float](repeating: 0, count: 1_600)))  // handled after the event, in order
        await waitUntil { h.coordinator.recordedSeconds > 0 }
        hold.release.fire()
        // Stop waits for the start to finish, so the state log below holds everything the start did.
        h.coordinator.stop()
        await waitUntil { h.coordinator.state.isFinished }
        XCTAssertTrue(h.states.all.contains(.paused(.interrupted)), "\(h.states.all)")
        XCTAssertFalse(h.states.all.contains(.recording), "never Recording while the call has it: \(h.states.all)")
        XCTAssertEqual(h.coordinator.state, .done)
    }

    // MARK: - Review R5-13: a row that could not be added

    /// The row could not be added when the recording stopped (a database error). The message says the recording is
    /// kept, and Retry adds the row (with its class) and transcribes, never "can no longer be retried".
    func testARowThatCouldNotBeAddedIsAddedByRetry() async throws {
        let h = Harness(testCase: self)
        await h.store.failNextInsert(with: FakeError(message: "database is locked"))
        h.coordinator.start(privacyClass: .clinical)
        await waitUntil { h.coordinator.state == .recording }
        let folder = try XCTUnwrap(h.wavURL).deletingLastPathComponent()
        await h.stopAndWait()

        guard case .failed(let message) = h.coordinator.state else { return XCTFail("\(h.coordinator.state)") }
        XCTAssertTrue(message.contains("The recording is saved"), message)
        XCTAssertFalse(message.contains("no longer"), message)
        XCTAssertTrue(h.coordinator.canRetry)
        let none = try await h.store.fetchAll()
        XCTAssertEqual(none, [])
        XCTAssertEqual(
            DictationCoordinator.recordedPrivacyClass(in: folder), .clinical,
            "until a row exists the class stays next to the audio, for the next launch")

        h.coordinator.retry()
        await waitUntil { h.coordinator.state.isFinished }
        XCTAssertEqual(h.coordinator.state, .done)
        let row = try await h.row()
        XCTAssertEqual(row.status, .completed)
        XCTAssertEqual(row.privacyClass, .clinical)
        XCTAssertEqual(row.durationMs, FakeCapture.recordedMs)
        XCTAssertEqual(h.clipboard.copies, [FakeSpeech.helloText])
        XCTAssertFalse(fileExists(folder.appendingPathComponent(DictationCoordinator.sessionFileName)))
    }

    // MARK: - Review R5-7: "Keep dictation audio" off

    /// The recording goes only after the transcript is saved: a failed save keeps the audio, so Retry still works.
    func testKeepAudioOffKeepsTheRecordingUntilTheTranscriptIsSaved() async throws {
        var settings = Harness.defaultSettings
        settings.keepDictationAudio = false
        let h = Harness(testCase: self, settings: settings)
        await h.store.failNextSave(with: FakeError(message: "disk full"))
        await h.startRecording()
        let wav = try XCTUnwrap(h.wavURL)
        await h.stopAndWait()

        guard case .failed = h.coordinator.state else { return XCTFail("\(h.coordinator.state)") }
        XCTAssertTrue(fileExists(wav), "the audio stays until its transcript is saved")
        XCTAssertTrue(h.coordinator.canRetry)

        h.coordinator.retry()
        await waitUntil { h.coordinator.state.isFinished }
        XCTAssertEqual(h.coordinator.state, .done)
        XCTAssertFalse(fileExists(wav))
        XCTAssertFalse(fileExists(wav.deletingLastPathComponent()))
        let row = try await h.row()
        XCTAssertEqual(row.rawTranscript, FakeSpeech.helloText)
        XCTAssertNil(row.mediaRelativePath)
        XCTAssertEqual(h.clipboard.copies, [FakeSpeech.helloText])
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

    // MARK: - Review R5-1: the class from the first write

    /// A dictation started Clinical (Create → Speak with Clinical on, a clinical recipe) is stored Clinical by its first
    /// write, never Personal, not even for a moment. While it records, the class sits next to its audio; once the row
    /// carries it, that file goes.
    func testAClinicalDictationIsStoredClinicalFromItsFirstWrite() async throws {
        let h = Harness(testCase: self)
        h.coordinator.start(privacyClass: .clinical)
        await waitUntil { h.coordinator.state == .recording }
        let folder = try XCTUnwrap(h.wavURL).deletingLastPathComponent()
        let marker = folder.appendingPathComponent(DictationCoordinator.sessionFileName)
        XCTAssertTrue(fileExists(marker), "the class is on disk while recording")
        XCTAssertEqual(DictationCoordinator.recordedPrivacyClass(in: folder), .clinical)

        await h.stopAndWait()
        XCTAssertEqual(h.coordinator.state, .done)
        let row = try await h.row()
        XCTAssertEqual(row.privacyClass, .clinical)
        let history = await h.store.classHistory(row.id)
        XCTAssertEqual(history.first, .clinical, "the insert itself is clinical")
        XCTAssertEqual(Set(history), [.clinical], "never Personal, not even for a moment")
        XCTAssertFalse(fileExists(marker), "the row carries the class now")
        XCTAssertTrue(fileExists(try XCTUnwrap(h.wavURL)))
    }

    func testAnOrdinaryDictationStaysPersonalAndAShortOneLeavesNoFolder() async throws {
        let h = Harness(testCase: self)
        await h.startRecording()
        await h.stopAndWait()
        let row = try await h.row()
        XCTAssertEqual(row.privacyClass, .personal)

        let short = Harness(testCase: self)
        short.capture.failStop(with: .tooShort)
        short.coordinator.start(privacyClass: .clinical)
        await waitUntil { short.coordinator.state == .recording }
        let folder = try XCTUnwrap(short.wavURL).deletingLastPathComponent()
        await short.stopAndWait()
        XCTAssertFalse(fileExists(folder), "the class file goes with the too-short recording")
    }

    /// A recording a killed process left behind is adopted with the class it was started with. An unknown class (an
    /// older build wrote none, the file is unreadable, or names a class this build does not know) reads as Clinical,
    /// the most protective class.
    func testLaunchAdoptsAKilledRecordingWithTheClassItWasStartedWith() async throws {
        let h = Harness(testCase: self)
        func orphan(_ privacyClass: PrivacyClass?, rawMarker: String? = nil) throws -> UUID {
            let id = UUID()
            let folder = h.paths.mediaDirectory(for: id)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(repeating: 3, count: 128).write(to: folder.appendingPathComponent(DictationCoordinator.fileName))
            if let privacyClass {
                try DictationCoordinator.writeSessionMarker(privacyClass, in: folder)
            } else if let rawMarker {
                try Data(rawMarker.utf8).write(
                    to: folder.appendingPathComponent(DictationCoordinator.sessionFileName))
            }
            return id
        }
        let expectations: [(UUID, PrivacyClass)] = [
            (try orphan(.clinical), .clinical),
            (try orphan(.personal), .personal),
            (try orphan(.general), .general),
            (try orphan(nil), .clinical),
            (try orphan(nil, rawMarker: "not json"), .clinical),
            (try orphan(nil, rawMarker: #"{"privacyClass":"top-secret"}"#), .clinical),
        ]

        let added = await h.coordinator.recoverOrphanedRecordings()
        XCTAssertEqual(added, expectations.count)
        for (id, expected) in expectations {
            let row = try await h.row(id)
            XCTAssertEqual(row.privacyClass, expected, "\(id)")
            let history = await h.store.classHistory(id)
            XCTAssertEqual(history, [expected], "adopted with its class by the insert itself")
            XCTAssertFalse(
                fileExists(h.paths.mediaDirectory(for: id).appendingPathComponent(DictationCoordinator.sessionFileName))
            )
        }
    }

    // MARK: - Review R5-4: a killed recording is transcribed whole

    /// A dictation killed while recording leaves a WAV that holds its samples but whose header says 0 s (real file
    /// bytes, written through AVAudioFile like the recorder). Adoption repairs the header first: the file reads back
    /// whole and the Library row has its length.
    func testLaunchAdoptsAKilledRecordingThatReadsBackWhole() async throws {
        let h = Harness(testCase: self)
        let id = UUID()
        let folder = h.paths.mediaDirectory(for: id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let wav = folder.appendingPathComponent(DictationCoordinator.fileName)
        try Self.writeKilledRecording(frames: 24_000, to: wav)
        XCTAssertEqual(try AVAudioFile(forReading: wav).length, 0, "what a kill leaves reads as 0 s")

        let added = await h.coordinator.recoverOrphanedRecordings()
        XCTAssertEqual(added, 1)
        XCTAssertEqual(try AVAudioFile(forReading: wav).length, 24_000, "every sample the kill left is readable")
        let row = try await h.row(id)
        XCTAssertEqual(row.status, .interrupted)
        XCTAssertEqual(row.durationMs, 1_500)
    }

    /// An older build adopted such a recording without the repair: Retry repairs it before the final pass reads it.
    func testRetryRepairsARecordingAnOlderBuildAdoptedBeforeTheFinalPassReadsIt() async throws {
        let h = Harness(testCase: self)
        let id = UUID()
        let folder = h.paths.mediaDirectory(for: id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let wav = folder.appendingPathComponent(DictationCoordinator.fileName)
        try Self.writeKilledRecording(frames: 16_000, to: wav)
        let adopted = Transcription(
            id: id, sourceType: .dictation, fileName: "Dictation.wav",
            mediaRelativePath: h.paths.relativePath(for: wav),
            status: .interrupted)
        try await h.store.insert(adopted)

        let hold = await h.speech.holdNextTranscription()
        let retry = Task { await h.coordinator.retry(transcriptionID: id) }
        await hold.entered.wait()
        XCTAssertEqual(try AVAudioFile(forReading: wav).length, 16_000, "repaired before the engine reads it")
        hold.release.fire()
        let saved = await retry.value
        XCTAssertEqual(saved?.status, .completed)
        XCTAssertEqual(saved?.durationMs, 1_000, "the recording's own length")
        XCTAssertEqual(saved?.isPartialAudio, true, "fix round 3: the header the pass rewrote was never closed")
    }

    /// Fix round 3: a final pass whose repair had to rewrite the header (an older build adopted the recording without
    /// the repair) marks the row partial audio at once, so a pass that then fails keeps the mark: the repaired file no
    /// longer shows it. A later pass never clears it.
    func testAFinalPassThatRewritesTheHeaderMarksTheRowPartialEvenWhenItFails() async throws {
        let h = Harness(testCase: self)
        let id = UUID()
        let folder = h.paths.mediaDirectory(for: id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let wav = folder.appendingPathComponent(DictationCoordinator.fileName)
        try Self.writeKilledRecording(frames: 16_000, to: wav)
        try await h.store.insert(
            Transcription(
                id: id, sourceType: .dictation, fileName: "Dictation.wav",
                mediaRelativePath: h.paths.relativePath(for: wav), status: .interrupted))

        await h.speech.failTranscription(with: FakeError(message: "engine stopped"))
        let failed = await h.coordinator.retry(transcriptionID: id)
        XCTAssertEqual(failed?.status, .failed)
        XCTAssertEqual(failed?.isPartialAudio, true, "kept although the pass failed after the repair")
        XCTAssertFalse(try SpeechWAVFile.repairHeader(at: wav).didRepair, "the file no longer shows the kill")

        await h.speech.failTranscription(with: nil)
        let saved = await h.coordinator.retry(transcriptionID: id)
        XCTAssertEqual(saved?.status, .completed)
        XCTAssertEqual(saved?.isPartialAudio, true, "never cleared")
    }

    /// Fix rounds 1 to 3 (minor 11): every orphan is adopted as partial audio, because nothing proves an orphan ran to
    /// its end: a WAV the recorder closed may still have stopped early (a full disk, review R2-6). Its sentence says
    /// only what is known. One whose header a kill left at 0 s was cut short by Parakeet closing, and says so. Both
    /// stay partial after a successful Retry.
    func testLaunchAdoptionMarksEveryOrphanPartialAndSaysOnlyWhatIsKnown() async throws {
        let h = Harness(testCase: self)
        let closed = UUID()
        let closedFolder = h.paths.mediaDirectory(for: closed)
        try FileManager.default.createDirectory(at: closedFolder, withIntermediateDirectories: true)
        try Self.writeRecording(
            frames: 16_000, to: closedFolder.appendingPathComponent(DictationCoordinator.fileName), killed: false)
        let killed = UUID()
        let killedFolder = h.paths.mediaDirectory(for: killed)
        try FileManager.default.createDirectory(at: killedFolder, withIntermediateDirectories: true)
        try Self.writeKilledRecording(
            frames: 16_000, to: killedFolder.appendingPathComponent(DictationCoordinator.fileName))

        let added = await h.coordinator.recoverOrphanedRecordings()
        XCTAssertEqual(added, 2)
        XCTAssertEqual(
            DictationCoordinator.adoptedSavedRecordingMessage,
            "The recording is saved, but Parakeet couldn’t add it to your Library then. Retry to transcribe what was saved."
        )
        XCTAssertEqual(
            DictationCoordinator.adoptedAfterKillMessage,
            "Parakeet closed while this dictation was recording. Retry to transcribe what was kept.")
        let closedRow = try await h.row(closed)
        XCTAssertEqual(closedRow.errorMessage, DictationCoordinator.adoptedSavedRecordingMessage)
        XCTAssertTrue(closedRow.isPartialAudio, "nothing proves an orphan ran to its end")
        let killedRow = try await h.row(killed)
        XCTAssertEqual(killedRow.errorMessage, DictationCoordinator.adoptedAfterKillMessage)
        XCTAssertTrue(killedRow.isPartialAudio, "its audio ends where Parakeet closed")
        XCTAssertEqual(closedRow.status, .interrupted)
        XCTAssertEqual(killedRow.status, .interrupted)

        for id in [closed, killed] {
            let retried = await h.coordinator.retry(transcriptionID: id)
            XCTAssertEqual(retried?.status, .completed)
            XCTAssertEqual(retried?.isPartialAudio, true, "still partial once transcribed")
        }
    }

    /// Fix rounds 2 and 3, the first double failure: a full disk stopped the dictation early (review R2-6), the
    /// recorder closed what it had saved, the row could not be added on that same disk (R5-13), and Parakeet then
    /// closed. The next launch adopts the recording with the saved sentence, as partial audio, and it stays partial
    /// after a successful Retry.
    func testAnEarlyStopWhoseRowCouldNotBeAddedEndsPartialAfterARelaunch() async throws {
        let h = Harness(testCase: self)
        await h.store.failNextInsert(with: FakeError(message: "disk full"))
        await h.startRecording()
        let wav = try XCTUnwrap(h.wavURL)
        let id = try XCTUnwrap(UUID(uuidString: wav.deletingLastPathComponent().lastPathComponent))
        // What the recorder saved before the disk filled, closed at its stop (real file bytes).
        try FileManager.default.removeItem(at: wav)
        try Self.writeRecording(frames: 8_000, to: wav, killed: false)
        h.capture.send(.event(.failed(message: Self.storageNotice)))
        await waitUntil { h.coordinator.state.isFinished }
        guard case .failed = h.coordinator.state else { return XCTFail("\(h.coordinator.state)") }
        let none = try await h.store.fetchAll()
        XCTAssertEqual(none, [], "the row could not be added")

        let relaunched = DictationCoordinator(
            capture: FakeCapture(), speech: h.speech, liveSessions: FakeLiveProvider(), scheduler: SpeechJobScheduler(),
            store: h.store, paths: h.paths, settings: h.settings, clipboard: FakeClipboard(),
            textRules: { DictationTextRules() }, voiceCommands: nil)
        let added = await relaunched.recoverOrphanedRecordings()
        XCTAssertEqual(added, 1)
        let row = try await h.row(id)
        XCTAssertEqual(row.errorMessage, DictationCoordinator.adoptedSavedRecordingMessage)
        XCTAssertTrue(row.isPartialAudio)
        XCTAssertEqual(row.status, .interrupted)
        XCTAssertEqual(row.durationMs, 500, "what was saved")

        let retried = await relaunched.retry(transcriptionID: id)
        XCTAssertEqual(retried?.status, .completed)
        XCTAssertEqual(retried?.isPartialAudio, true, "still partial once transcribed")
    }

    /// Fix rounds 2 and 3, the second double failure: a launch repaired a killed recording's header, and then its row
    /// could not be added, or Parakeet was killed before the insert. The next launch finds a closed header: the saved
    /// sentence, as partial audio, and it stays partial after a successful Retry.
    func testAKilledRecordingWhoseAdoptionFailedEndsPartial() async throws {
        let h = Harness(testCase: self)
        func killedRecording() throws -> (id: UUID, wav: URL) {
            let id = UUID()
            let folder = h.paths.mediaDirectory(for: id)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let wav = folder.appendingPathComponent(DictationCoordinator.fileName)
            try Self.writeKilledRecording(frames: 16_000, to: wav)
            return (id, wav)
        }
        // The launch repaired the header, then the insert failed.
        let insertFailed = try killedRecording()
        await h.store.failNextInsert(with: FakeError(message: "disk full"))
        let first = await h.coordinator.recoverOrphanedRecordings()
        XCTAssertEqual(first, 0)
        // The launch repaired the header and was killed before the insert.
        let killedBeforeInsert = try killedRecording()
        try SpeechWAVFile.repairHeader(at: killedBeforeInsert.wav)

        let added = await h.coordinator.recoverOrphanedRecordings()
        XCTAssertEqual(added, 2)
        for id in [insertFailed.id, killedBeforeInsert.id] {
            let row = try await h.row(id)
            XCTAssertEqual(row.errorMessage, DictationCoordinator.adoptedSavedRecordingMessage)
            XCTAssertTrue(row.isPartialAudio)
            XCTAssertEqual(row.status, .interrupted)
            XCTAssertEqual(row.durationMs, 1_000)

            let retried = await h.coordinator.retry(transcriptionID: id)
            XCTAssertEqual(retried?.status, .completed)
            XCTAssertEqual(retried?.isPartialAudio, true, "still partial once transcribed")
        }
    }

    // MARK: - Fix round 2: a dictation that stopped on its own stays marked

    /// The notice the recorder sends when a write fails (a full disk, review R2-6).
    private static let storageNotice =
        "Stopped early: the iPhone may be out of storage, so Parakeet could not save more audio."

    /// Review R2-6: a dictation that stopped on its own (here a full disk) is saved as partial audio, so the Library
    /// still says it was cut short once the outcome's notice and the Lock Screen activity are gone. An ordinary
    /// dictation is not.
    func testADictationThatStoppedOnItsOwnIsSavedAsPartialAudio() async throws {
        let h = Harness(testCase: self)
        await h.startRecording()
        h.capture.send(.event(.failed(message: Self.storageNotice)))
        await waitUntil { h.coordinator.state.isFinished }
        XCTAssertEqual(h.coordinator.state, .done)
        let partial = try await h.row()
        XCTAssertEqual(partial.status, .completed)
        XCTAssertNil(partial.errorMessage)
        XCTAssertTrue(partial.isPartialAudio, "the Library says it was cut short")

        h.coordinator.dismiss()
        await h.startRecording()
        // What the recorder leaves at an ordinary Stop: a closed WAV (real file bytes), which the final pass's repair
        // leaves alone.
        let wav = try XCTUnwrap(h.wavURL)
        try FileManager.default.removeItem(at: wav)
        try Self.writeRecording(frames: 16_000, to: wav, killed: false)
        await h.stopAndWait()
        XCTAssertEqual(h.coordinator.state, .done)
        let whole = try await h.row()
        XCTAssertNotEqual(whole.id, partial.id)
        XCTAssertFalse(whole.isPartialAudio, "an ordinary stop is not partial audio")
    }

    /// The same when only Retry could add the row (review R5-13).
    func testAPartialDictationWhoseRowRetryAddedIsStillPartial() async throws {
        let h = Harness(testCase: self)
        await h.store.failNextInsert(with: FakeError(message: "disk full"))
        await h.startRecording()
        h.capture.send(.event(.failed(message: "The microphone stopped and could not restart.")))
        await waitUntil { h.coordinator.state.isFinished }
        guard case .failed = h.coordinator.state else { return XCTFail("\(h.coordinator.state)") }

        h.coordinator.retry()
        await waitUntil { h.coordinator.state.isFinished }
        XCTAssertEqual(h.coordinator.state, .done)
        let row = try await h.row()
        XCTAssertEqual(row.status, .completed)
        XCTAssertTrue(row.isPartialAudio)
    }

    /// Writes `frames` of a synthetic tone as the recorder does (AVAudioFile, 16 kHz mono Float32 WAV) and leaves at
    /// `url` exactly what a kill leaves: the file as it is before `close()`.
    static func writeKilledRecording(frames: Int, to url: URL) throws {
        try writeRecording(frames: frames, to: url, killed: true)
    }

    /// `writeKilledRecording`, or with `killed` false the closed file a normal stop leaves.
    static func writeRecording(frames: Int, to url: URL, killed: Bool) throws {
        let open =
            killed ? url.deletingLastPathComponent().appendingPathComponent("open-\(UUID().uuidString).wav") : url
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000.0, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(
            forWriting: open, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = try XCTUnwrap(
            AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        buffer.frameLength = AVAudioFrameCount(frames)
        for index in 0..<frames { buffer.floatChannelData![0][index] = 0.3 * sinf(Float(index) * 0.06) }
        try file.write(from: buffer)
        guard killed else {
            file.close()
            return
        }
        try FileManager.default.copyItem(at: open, to: url)
        file.close()
        try FileManager.default.removeItem(at: open)
    }

    /// Cancel, then start again at once: the new dictation waits for the discard, keeps its own recording, and the
    /// discarded one leaves nothing.
    func testStartingRightAfterACancelKeepsTheNewRecordingAndDiscardsTheOld() async throws {
        let h = Harness(testCase: self)
        await h.startRecording()
        let oldFolder = try XCTUnwrap(h.wavURL).deletingLastPathComponent()
        h.coordinator.cancel()
        h.coordinator.dismiss()
        h.coordinator.start()
        await waitUntil { h.coordinator.state == .recording }
        let newURL = try XCTUnwrap(h.wavURL)
        XCTAssertNotEqual(newURL.deletingLastPathComponent(), oldFolder)
        XCTAssertFalse(fileExists(oldFolder))
        XCTAssertTrue(fileExists(newURL))
        await h.stopAndWait()
        XCTAssertEqual(h.coordinator.state, .done)
        let rows = try await h.store.fetchAll()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.mediaRelativePath, h.paths.relativePath(for: newURL))
    }

    func testWaitForStateReturnsWhenRecordingBeginsAndWhenTheDictationEnds() async throws {
        let h = Harness(testCase: self)
        h.coordinator.start()
        await h.coordinator.waitForState { $0 == .recording || $0.isFinished }
        XCTAssertEqual(h.coordinator.state, .recording)
        h.coordinator.stop()
        await h.coordinator.waitForState(\.isFinished)
        XCTAssertEqual(h.coordinator.state, .done)
        await h.coordinator.waitForState(\.isFinished)  // already there: returns at once
    }
}
