import ChirpFeatures
import Foundation

/// Runs the meeting Live Activity's intents (`App/Shared/MeetingIntents.swift`) against the app's one meeting
/// coordinator.
@MainActor enum MeetingIntentRouter {
    /// Stops and saves; returns once the meeting is saved or failed, so iOS keeps the app running for the final pass.
    static func stop() async {
        guard case .ready(let environment) = AppEnvironment.shared else { return }
        let meeting = environment.meeting
        guard meeting.state.isCapturing else { return }
        meeting.stop()
        await meeting.waitForState(\.isFinished)
    }

    static func togglePause() {
        guard case .ready(let environment) = AppEnvironment.shared else { return }
        let meeting = environment.meeting
        switch meeting.state {
        case .recording: meeting.pause()
        case .paused, .waitingForResume: meeting.resume()
        default: break
        }
    }
}
