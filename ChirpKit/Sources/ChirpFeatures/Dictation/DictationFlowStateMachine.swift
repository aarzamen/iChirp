// Ported from MacParakeet (GPL-3.0): Sources/MacParakeetCore/DictationFlow/DictationFlowStateMachine.swift @ bbae9e0e
// Changes: iPhone flow only. Kept: a pure value type, events in → state + effects out, a generation that bumps on
// every start and rejects stale async completions, stop-while-starting as `pendingStop`, and a busy start that never
// cancels a running final pass. Dropped: the ready pill, entitlements, hotkey modes, menu bar, paste and the undo
// countdown (iOS cannot paste into other apps). Added: interruption pause/resume and a Retry of a failed final pass.

import Foundation

/// Why a recording is paused.
public enum DictationPause: Equatable, Sendable {
    /// A call, Siri or an alarm has the microphone; it resumes by itself if iOS says so.
    case interrupted
    /// The interruption ended without iOS asking to resume: the person taps Resume or Stop.
    case waitingForResume
}

/// The states of one dictation, from start to its outcome.
public enum DictationFlowState: Equatable, Sendable {
    case idle
    /// Model and permission checks and the microphone start are in flight.
    case starting
    case recording
    case paused(DictationPause)
    /// Stop was pressed while the microphone was still starting; it stops as soon as recording begins.
    case pendingStop
    /// The final Parakeet pass (and saving) runs.
    case stopping
    /// The final text is on the clipboard and the row is saved.
    case done
    /// Nothing was copied. The message says why; Retry is offered when a recording was kept.
    case failed(String)
    /// The person discarded the dictation: no row, no audio.
    case cancelled

    /// A recording is running (possibly paused).
    public var isCapturing: Bool {
        switch self {
        case .recording, .paused: true
        default: false
        }
    }

    /// The flow has ended; a new start is allowed.
    public var isFinished: Bool {
        switch self {
        case .idle, .done, .failed, .cancelled: true
        default: false
        }
    }
}

/// Everything that drives the flow. Async completions carry the generation they belong to.
public enum DictationFlowEvent: Equatable, Sendable {
    case startRequested
    case stopRequested
    case cancelRequested
    case resumeRequested
    case retryRequested
    case dismissRequested

    case recordingStarted(generation: Int)
    case startFailed(generation: Int, message: String)
    case captureInterrupted(generation: Int)
    case captureWaitingForResume(generation: Int)
    case captureResumed(generation: Int)
    /// The microphone died and could not restart: keep what was recorded and run the final pass.
    case captureFailed(generation: Int)
    case transcriptionCompleted(generation: Int)
    case transcriptionFailedNoSpeech(generation: Int)
    case transcriptionFailed(generation: Int, message: String)
}

/// Side effects for the coordinator to run.
public enum DictationFlowEffect: Equatable, Sendable {
    /// Check the model and the microphone permission, then start recording.
    case startRecording
    /// Stop recording, finish the live preview, save the row, run the final pass, copy.
    case stopRecordingAndTranscribe
    /// Discard: stop and delete the recording (no row).
    case cancelRecording
    /// Discard during the final pass: stop it, then delete the row and its audio.
    case cancelFinalPass
    case resumeCapture
    /// Run the final pass again on the kept recording.
    case retryFinalPass
    /// A start arrived while the final pass runs: nothing is cancelled; the screen says it is busy.
    case showBusy
}

/// Pure, deterministic flow for one dictation at a time. The coordinator calls `handle(_:)` and runs the effects.
public struct DictationFlowStateMachine: Sendable, Equatable {
    public private(set) var state: DictationFlowState = .idle
    public private(set) var generation = 0

    public static let noSpeechMessage = "Didn’t catch that — no speech was recognized."

    public init() {}

    /// Applies `event`; returns the effects to run (empty when the event is invalid here or stale).
    public mutating func handle(_ event: DictationFlowEvent) -> [DictationFlowEffect] {
        switch (state, event) {
        // MARK: Start
        case (let current, .startRequested) where current.isFinished:
            generation += 1
            state = .starting
            return [.startRecording]
        case (.stopping, .startRequested):
            return [.showBusy]

        // MARK: Starting
        case (.starting, .recordingStarted(let gen)):
            guard gen == generation else { return [] }
            state = .recording
            return []
        case (.starting, .startFailed(let gen, let message)), (.pendingStop, .startFailed(let gen, let message)):
            guard gen == generation else { return [] }
            state = .failed(message)
            return []
        case (.starting, .stopRequested):
            state = .pendingStop
            return []
        case (.starting, .cancelRequested), (.pendingStop, .cancelRequested):
            state = .cancelled
            return [.cancelRecording]

        // MARK: Pending stop
        case (.pendingStop, .recordingStarted(let gen)):
            guard gen == generation else { return [] }
            state = .stopping
            return [.stopRecordingAndTranscribe]

        // MARK: Recording and paused
        case (.recording, .stopRequested), (.paused, .stopRequested):
            state = .stopping
            return [.stopRecordingAndTranscribe]
        case (.recording, .cancelRequested), (.paused, .cancelRequested):
            state = .cancelled
            return [.cancelRecording]
        case (.recording, .captureInterrupted(let gen)):
            guard gen == generation else { return [] }
            state = .paused(.interrupted)
            return []
        case (.paused, .captureWaitingForResume(let gen)), (.recording, .captureWaitingForResume(let gen)):
            guard gen == generation else { return [] }
            state = .paused(.waitingForResume)
            return []
        case (.paused, .captureResumed(let gen)):
            guard gen == generation else { return [] }
            state = .recording
            return []
        case (.paused, .resumeRequested):
            return [.resumeCapture]
        case (.recording, .captureFailed(let gen)), (.paused, .captureFailed(let gen)):
            guard gen == generation else { return [] }
            state = .stopping
            return [.stopRecordingAndTranscribe]

        // MARK: Final pass
        case (.stopping, .transcriptionCompleted(let gen)):
            guard gen == generation else { return [] }
            state = .done
            return []
        case (.stopping, .transcriptionFailedNoSpeech(let gen)):
            guard gen == generation else { return [] }
            state = .failed(Self.noSpeechMessage)
            return []
        case (.stopping, .transcriptionFailed(let gen, let message)):
            guard gen == generation else { return [] }
            state = .failed(message)
            return []
        case (.stopping, .cancelRequested):
            state = .cancelled
            return [.cancelFinalPass]

        // MARK: Outcomes
        case (.failed, .retryRequested):
            state = .stopping
            return [.retryFinalPass]
        case (.done, .dismissRequested), (.failed, .dismissRequested), (.cancelled, .dismissRequested):
            state = .idle
            return []

        default:
            return []
        }
    }
}
