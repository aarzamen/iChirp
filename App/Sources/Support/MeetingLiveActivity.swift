import ActivityKit
import ChirpCore
import ChirpFeatures
import Foundation

/// Keeps the meeting Live Activity in step with the coordinator (M3): it starts when recording begins, shows Paused,
/// Interrupted and Finishing, and ends a few seconds after Saved or a failure (at once when the meeting is discarded).
/// Without Live Activities allowed, meetings still record in the app.
///
/// Review R5-11: every update and end goes through one `LiveActivityUpdateChain`, so they reach the Lock Screen in the
/// order the states happened.
@MainActor final class MeetingLiveActivity {
    /// What the activity does for a state (pure, so `LiveActivityContentTests` checks it without ActivityKit).
    enum Update: Equatable {
        case show(MeetingActivityAttributes.ContentState)
        case end(MeetingActivityAttributes.ContentState?, after: TimeInterval)
        case none
    }

    private var activity: Activity<MeetingActivityAttributes>?
    private let updates = LiveActivityUpdateChain()
    private let logger = Log.logger("meeting-live-activity")

    func update(for state: MeetingFlowState, recordedSeconds: TimeInterval, title: String) {
        switch Self.update(for: state, recordedSeconds: recordedSeconds, now: Date()) {
        case .show(let content): show(content, title: title)
        case .end(let content, let seconds): end(content, after: seconds)
        case .none: break
        }
    }

    static func update(for state: MeetingFlowState, recordedSeconds: TimeInterval, now: Date) -> Update {
        let timerStart = now.addingTimeInterval(-recordedSeconds)
        func content(_ phase: MeetingActivityAttributes.ContentState.Phase, _ detail: String?)
            -> MeetingActivityAttributes.ContentState
        {
            .init(phase: phase, timerStart: timerStart, recordedSeconds: Int(recordedSeconds), detail: detail)
        }
        switch state {
        case .recording:
            return .show(content(.recording, "Microphone · saving on this iPhone"))
        case .paused:
            return .show(content(.paused, "Paused · nothing is recorded"))
        case .interrupted:
            return .show(content(.interrupted, "A call or Siri has the microphone"))
        case .waitingForResume:
            return .show(content(.interrupted, "Open Parakeet and tap Resume"))
        case .stopping:
            return .show(content(.finishing, "Transcribing on this iPhone"))
        case .saved:
            return .end(content(.saved, "Transcript saved"), after: 5)
        case .failed(let message, _):
            return .end(content(.failed, message), after: 8)
        case .idle:
            return .end(nil, after: 0)
        case .starting:
            return .none
        }
    }

    private func show(_ state: MeetingActivityAttributes.ContentState, title: String) {
        let content = ActivityContent(state: state, staleDate: nil)
        if let activity {
            // ActivityKit's `Activity` is not Sendable; it is only used from this main-actor owner.
            nonisolated(unsafe) let current = activity
            updates.enqueue { await current.update(content) }
            return
        }
        guard state.phase == .recording, ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        do {
            activity = try Activity.request(
                attributes: MeetingActivityAttributes(title: title), content: content, pushType: nil)
            logger.notice("meeting_live_activity_started")
        } catch {
            logger.error(
                "meeting_live_activity_failed error_type=\(String(describing: type(of: error)), privacy: .public)")
        }
    }

    private func end(_ state: MeetingActivityAttributes.ContentState?, after seconds: TimeInterval) {
        guard let activity else { return }
        self.activity = nil
        let content = state.map { ActivityContent(state: $0, staleDate: nil) }
        let policy: ActivityUIDismissalPolicy = seconds > 0 ? .after(Date().addingTimeInterval(seconds)) : .immediate
        nonisolated(unsafe) let ending = activity
        updates.enqueue { await ending.end(content, dismissalPolicy: policy) }
    }
}
