import ActivityKit
import ChirpCore
import ChirpFeatures
import Foundation

/// Keeps the meeting Live Activity in step with the coordinator (M3): it starts when recording begins, shows Paused,
/// Interrupted and Finishing, and ends a few seconds after Saved or a failure (at once when the meeting is discarded).
/// Without Live Activities allowed, meetings still record in the app.
@MainActor final class MeetingLiveActivity {
    private var activity: Activity<MeetingActivityAttributes>?
    private let logger = Log.logger("meeting-live-activity")

    func update(for state: MeetingFlowState, recordedSeconds: TimeInterval, title: String) {
        let seconds = Int(recordedSeconds)
        let timerStart = Date().addingTimeInterval(-recordedSeconds)
        func content(_ phase: MeetingActivityAttributes.ContentState.Phase, _ detail: String?)
            -> MeetingActivityAttributes.ContentState
        {
            .init(phase: phase, timerStart: timerStart, recordedSeconds: seconds, detail: detail)
        }
        switch state {
        case .recording:
            show(content(.recording, "Microphone · saving on this iPhone"), title: title)
        case .paused:
            show(content(.paused, "Paused · nothing is recorded"), title: title)
        case .interrupted:
            show(content(.interrupted, "A call or Siri has the microphone"), title: title)
        case .waitingForResume:
            show(content(.interrupted, "Open Parakeet and tap Resume"), title: title)
        case .stopping:
            show(content(.finishing, "Transcribing on this iPhone"), title: title)
        case .saved:
            end(content(.saved, "Transcript saved"), after: 5)
        case .failed(let message, _):
            end(content(.failed, message), after: 8)
        case .idle:
            end(nil, after: 0)
        case .starting:
            break
        }
    }

    private func show(_ state: MeetingActivityAttributes.ContentState, title: String) {
        let content = ActivityContent(state: state, staleDate: nil)
        if let activity {
            // ActivityKit's `Activity` is not Sendable; it is only used from this main-actor owner.
            nonisolated(unsafe) let current = activity
            Task { await current.update(content) }
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
        Task { await ending.end(content, dismissalPolicy: policy) }
    }
}
