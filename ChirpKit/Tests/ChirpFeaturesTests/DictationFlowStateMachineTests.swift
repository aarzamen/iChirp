// Ported from MacParakeet (GPL-3.0): Tests/MacParakeetTests/DictationFlow/DictationFlowStateMachineTests.swift @ bbae9e0e
// Changes: the tests whose transitions exist on the iPhone keep their upstream names (ready pill, entitlements,
// hotkey modes, paste and the undo countdown are gone); interruption and Retry tests are new.

import XCTest

@testable import ChirpFeatures

final class DictationFlowStateMachineTests: XCTestCase {
    private func recordingMachine() -> DictationFlowStateMachine {
        var machine = DictationFlowStateMachine()
        _ = machine.handle(.startRequested)
        _ = machine.handle(.recordingStarted(generation: machine.generation))
        return machine
    }

    private func stoppingMachine() -> DictationFlowStateMachine {
        var machine = recordingMachine()
        _ = machine.handle(.stopRequested)
        return machine
    }

    // MARK: - Idle

    func testInitialStateIsIdle() {
        let machine = DictationFlowStateMachine()
        XCTAssertEqual(machine.state, .idle)
        XCTAssertEqual(machine.generation, 0)
    }

    func testIdleStartRequested() {
        var machine = DictationFlowStateMachine()
        XCTAssertEqual(machine.handle(.startRequested), [.startRecording])
        XCTAssertEqual(machine.state, .starting)
        XCTAssertEqual(machine.generation, 1)
    }

    func testIdleIgnoresInvalidEvents() {
        var machine = DictationFlowStateMachine()
        for event: DictationFlowEvent in [
            .stopRequested, .cancelRequested, .resumeRequested, .retryRequested, .dismissRequested,
            .recordingStarted(generation: 0), .transcriptionCompleted(generation: 0),
            .captureInterrupted(generation: 0),
        ] {
            XCTAssertEqual(machine.handle(event), [], "\(event)")
            XCTAssertEqual(machine.state, .idle)
        }
    }

    func testIdleToStartBumpsGeneration() {
        var machine = DictationFlowStateMachine()
        _ = machine.handle(.startRequested)
        let first = machine.generation
        _ = machine.handle(.cancelRequested)
        _ = machine.handle(.startRequested)
        XCTAssertEqual(machine.generation, first + 1)
    }

    // MARK: - Starting

    func testStartingServiceRecordingStarted() {
        var machine = DictationFlowStateMachine()
        _ = machine.handle(.startRequested)
        XCTAssertEqual(machine.handle(.recordingStarted(generation: machine.generation)), [])
        XCTAssertEqual(machine.state, .recording)
    }

    func testStartingServiceStartFailed() {
        var machine = DictationFlowStateMachine()
        _ = machine.handle(.startRequested)
        _ = machine.handle(.startFailed(generation: machine.generation, message: "No microphone"))
        XCTAssertEqual(machine.state, .failed("No microphone"))
    }

    func testStartingServiceStopRequested() {
        var machine = DictationFlowStateMachine()
        _ = machine.handle(.startRequested)
        XCTAssertEqual(machine.handle(.stopRequested), [])
        XCTAssertEqual(machine.state, .pendingStop)
    }

    func testStartingServiceCancelRequested() {
        var machine = DictationFlowStateMachine()
        _ = machine.handle(.startRequested)
        XCTAssertEqual(machine.handle(.cancelRequested), [.cancelRecording])
        XCTAssertEqual(machine.state, .cancelled)
    }

    func testStartingServiceStaleRecordingStarted() {
        var machine = DictationFlowStateMachine()
        _ = machine.handle(.startRequested)
        XCTAssertEqual(machine.handle(.recordingStarted(generation: machine.generation - 1)), [])
        XCTAssertEqual(machine.state, .starting)
    }

    // MARK: - Pending stop

    func testPendingStopRecordingStarted() {
        var machine = DictationFlowStateMachine()
        _ = machine.handle(.startRequested)
        _ = machine.handle(.stopRequested)
        XCTAssertEqual(machine.handle(.recordingStarted(generation: machine.generation)), [.stopRecordingAndTranscribe])
        XCTAssertEqual(machine.state, .stopping)
    }

    func testPendingStopStartFailed() {
        var machine = DictationFlowStateMachine()
        _ = machine.handle(.startRequested)
        _ = machine.handle(.stopRequested)
        _ = machine.handle(.startFailed(generation: machine.generation, message: "Denied"))
        XCTAssertEqual(machine.state, .failed("Denied"))
    }

    func testPendingStopCancelRequested() {
        var machine = DictationFlowStateMachine()
        _ = machine.handle(.startRequested)
        _ = machine.handle(.stopRequested)
        XCTAssertEqual(machine.handle(.cancelRequested), [.cancelRecording])
        XCTAssertEqual(machine.state, .cancelled)
    }

    func testPendingStopFullFlow() {
        var machine = DictationFlowStateMachine()
        _ = machine.handle(.startRequested)
        _ = machine.handle(.stopRequested)
        _ = machine.handle(.recordingStarted(generation: machine.generation))
        _ = machine.handle(.transcriptionCompleted(generation: machine.generation))
        XCTAssertEqual(machine.state, .done)
    }

    // MARK: - Recording

    func testRecordingStopRequested() {
        var machine = recordingMachine()
        XCTAssertEqual(machine.handle(.stopRequested), [.stopRecordingAndTranscribe])
        XCTAssertEqual(machine.state, .stopping)
    }

    func testRecordingCancelRequestedUI() {
        var machine = recordingMachine()
        XCTAssertEqual(machine.handle(.cancelRequested), [.cancelRecording])
        XCTAssertEqual(machine.state, .cancelled)
    }

    func testRecordingIgnoresASecondStart() {
        var machine = recordingMachine()
        XCTAssertEqual(machine.handle(.startRequested), [])
        XCTAssertEqual(machine.state, .recording)
    }

    // MARK: - Interruptions (iPhone)

    func testInterruptionPausesAndCaptureResumeContinues() {
        var machine = recordingMachine()
        let gen = machine.generation
        _ = machine.handle(.captureInterrupted(generation: gen))
        XCTAssertEqual(machine.state, .paused(.interrupted))
        _ = machine.handle(.captureWaitingForResume(generation: gen))
        XCTAssertEqual(machine.state, .paused(.waitingForResume))
        XCTAssertEqual(machine.handle(.resumeRequested), [.resumeCapture])
        XCTAssertEqual(machine.state, .paused(.waitingForResume), "state changes only when audio flows again")
        _ = machine.handle(.captureResumed(generation: gen))
        XCTAssertEqual(machine.state, .recording)
    }

    func testPausedStopKeepsTheRecordingAndTranscribes() {
        var machine = recordingMachine()
        _ = machine.handle(.captureInterrupted(generation: machine.generation))
        XCTAssertEqual(machine.handle(.stopRequested), [.stopRecordingAndTranscribe])
        XCTAssertEqual(machine.state, .stopping)
    }

    func testCaptureFailureFinalizesWhatWasRecorded() {
        var machine = recordingMachine()
        XCTAssertEqual(machine.handle(.captureFailed(generation: machine.generation)), [.stopRecordingAndTranscribe])
        XCTAssertEqual(machine.state, .stopping)
    }

    // MARK: - Processing (final pass)

    func testProcessingTranscriptionCompleted() {
        var machine = stoppingMachine()
        _ = machine.handle(.transcriptionCompleted(generation: machine.generation))
        XCTAssertEqual(machine.state, .done)
    }

    func testProcessingTranscriptionFailedNoSpeech() {
        var machine = stoppingMachine()
        _ = machine.handle(.transcriptionFailedNoSpeech(generation: machine.generation))
        XCTAssertEqual(machine.state, .failed(DictationFlowStateMachine.noSpeechMessage))
    }

    func testProcessingTranscriptionFailed() {
        var machine = stoppingMachine()
        _ = machine.handle(.transcriptionFailed(generation: machine.generation, message: "Engine error"))
        XCTAssertEqual(machine.state, .failed("Engine error"))
    }

    func testProcessingCancelRequested() {
        var machine = stoppingMachine()
        XCTAssertEqual(machine.handle(.cancelRequested), [.cancelFinalPass])
        XCTAssertEqual(machine.state, .cancelled)
    }

    func testProcessingStaleTranscriptionCompleted() {
        var machine = stoppingMachine()
        XCTAssertEqual(machine.handle(.transcriptionCompleted(generation: machine.generation + 1)), [])
        XCTAssertEqual(machine.state, .stopping)
    }

    func testStartRequestedWhileProcessingShowsBusyHintWithoutCancellingTranscription() {
        var machine = stoppingMachine()
        XCTAssertEqual(machine.handle(.startRequested), [.showBusy])
        XCTAssertEqual(machine.state, .stopping)
    }

    // MARK: - Finishing

    func testFailedRetryRunsTheFinalPassAgain() {
        var machine = stoppingMachine()
        _ = machine.handle(.transcriptionFailed(generation: machine.generation, message: "Boom"))
        XCTAssertEqual(machine.handle(.retryRequested), [.retryFinalPass])
        XCTAssertEqual(machine.state, .stopping)
        _ = machine.handle(.transcriptionCompleted(generation: machine.generation))
        XCTAssertEqual(machine.state, .done)
    }

    func testFinishingDismissRequested() {
        for outcome: DictationFlowEvent in [
            .transcriptionCompleted(generation: 1), .transcriptionFailed(generation: 1, message: "x"),
        ] {
            var machine = stoppingMachine()
            _ = machine.handle(outcome)
            _ = machine.handle(.dismissRequested)
            XCTAssertEqual(machine.state, .idle)
        }
    }

    func testFinishingStartRequested() {
        var machine = stoppingMachine()
        _ = machine.handle(.transcriptionCompleted(generation: machine.generation))
        XCTAssertEqual(machine.handle(.startRequested), [.startRecording])
        XCTAssertEqual(machine.state, .starting)
        XCTAssertEqual(machine.generation, 2)
    }

    func testFinishingSuccessStartRequestedIgnoresStaleCallback() {
        var machine = stoppingMachine()
        let old = machine.generation
        _ = machine.handle(.transcriptionCompleted(generation: old))
        _ = machine.handle(.startRequested)
        XCTAssertEqual(machine.handle(.recordingStarted(generation: old)), [])
        XCTAssertEqual(machine.state, .starting)
    }

    // MARK: - Integration

    func testHappyPathPersistent() {
        var machine = DictationFlowStateMachine()
        XCTAssertEqual(machine.handle(.startRequested), [.startRecording])
        let gen = machine.generation
        XCTAssertEqual(machine.handle(.recordingStarted(generation: gen)), [])
        XCTAssertEqual(machine.handle(.stopRequested), [.stopRecordingAndTranscribe])
        XCTAssertEqual(machine.handle(.transcriptionCompleted(generation: gen)), [])
        XCTAssertEqual(machine.state, .done)
        XCTAssertEqual(machine.handle(.dismissRequested), [])
        XCTAssertEqual(machine.state, .idle)
    }

    func testAllAsyncEventsRejectedWithStaleGeneration() {
        let stale = 0
        let events: [DictationFlowEvent] = [
            .recordingStarted(generation: stale), .startFailed(generation: stale, message: "x"),
            .captureInterrupted(generation: stale), .captureWaitingForResume(generation: stale),
            .captureResumed(generation: stale), .captureFailed(generation: stale),
            .transcriptionCompleted(generation: stale), .transcriptionFailedNoSpeech(generation: stale),
            .transcriptionFailed(generation: stale, message: "x"),
        ]
        for event in events {
            for var machine in [recordingMachine(), stoppingMachine()] {
                let before = machine.state
                XCTAssertEqual(machine.handle(event), [], "\(event)")
                XCTAssertEqual(machine.state, before, "\(event)")
            }
        }
    }
}
