import XCTest

@testable import ChirpFeatures

/// UX audit F72: Cancel on the Dictating screen asks before it throws away anything longer than a false start.
final class DictationDiscardPromptTests: XCTestCase {
    func testAFalseStartIsDiscardedWithoutAQuestion() {
        XCTAssertNil(DictationDiscardPrompt.forCancel(state: .recording, recordedSeconds: 0))
        XCTAssertNil(DictationDiscardPrompt.forCancel(state: .recording, recordedSeconds: 4.9))
        XCTAssertNil(DictationDiscardPrompt.forCancel(state: .starting, recordedSeconds: 0))
        XCTAssertNil(DictationDiscardPrompt.forCancel(state: .pendingStop, recordedSeconds: 0))
    }

    func testARecordingPastTheThresholdAsksWithItsLength() throws {
        let prompt = try XCTUnwrap(DictationDiscardPrompt.forCancel(state: .recording, recordedSeconds: 5))
        XCTAssertEqual(prompt.title, "Discard this 5-second dictation?")
        XCTAssertEqual(prompt.discardTitle, "Discard dictation")
        XCTAssertEqual(prompt.keepTitle, "Keep dictating")
        XCTAssertTrue(prompt.message.contains("Nothing is copied"))

        let long = try XCTUnwrap(DictationDiscardPrompt.forCancel(state: .recording, recordedSeconds: 185))
        XCTAssertEqual(long.title, "Discard this 3-minute dictation?")
    }

    func testAPausedRecordingAsksToo() throws {
        let interrupted = try XCTUnwrap(
            DictationDiscardPrompt.forCancel(state: .paused(.interrupted), recordedSeconds: 42))
        XCTAssertEqual(interrupted.title, "Discard this 42-second dictation?")
        XCTAssertNotNil(DictationDiscardPrompt.forCancel(state: .paused(.waitingForResume), recordedSeconds: 42))
    }

    func testCancelDuringTheFinalPassAsksAndSaysTheTranscriptionStops() throws {
        let prompt = try XCTUnwrap(DictationDiscardPrompt.forCancel(state: .stopping, recordedSeconds: 90))
        XCTAssertEqual(prompt.title, "Discard this 2-minute dictation?")
        XCTAssertEqual(prompt.keepTitle, "Keep transcribing")
        XCTAssertTrue(prompt.message.contains("transcription stops"))
    }

    func testNothingIsAskedOnceTheDictationHasEnded() {
        for state: DictationFlowState in [.idle, .done, .failed("x"), .cancelled] {
            XCTAssertFalse(DictationDiscardPrompt.canDiscard(in: state), "\(state)")
            XCTAssertNil(DictationDiscardPrompt.forCancel(state: state, recordedSeconds: 300), "\(state)")
        }
        for state: DictationFlowState in [.starting, .recording, .paused(.interrupted), .pendingStop, .stopping] {
            XCTAssertTrue(DictationDiscardPrompt.canDiscard(in: state), "\(state)")
        }
    }

    func testLengthPhrases() {
        XCTAssertEqual(DictationDiscardPrompt.lengthPhrase(seconds: 12.7), "12-second")
        XCTAssertEqual(DictationDiscardPrompt.lengthPhrase(seconds: 59.9), "59-second")
        XCTAssertEqual(DictationDiscardPrompt.lengthPhrase(seconds: 60), "1-minute")
        XCTAssertEqual(DictationDiscardPrompt.lengthPhrase(seconds: 89), "1-minute")
        XCTAssertEqual(DictationDiscardPrompt.lengthPhrase(seconds: 90), "2-minute")
        XCTAssertEqual(DictationDiscardPrompt.lengthPhrase(seconds: 3_600), "60-minute")
    }

    /// The prompt only asks: the discard is still the state machine's explicit Cancel, unchanged.
    func testTheDiscardItselfIsStillTheFlowsCancel() {
        var machine = DictationFlowStateMachine()
        _ = machine.handle(.startRequested)
        _ = machine.handle(.recordingStarted(generation: machine.generation))
        XCTAssertEqual(machine.handle(.cancelRequested), [.cancelRecording])
        XCTAssertEqual(machine.state, .cancelled)
    }
}
