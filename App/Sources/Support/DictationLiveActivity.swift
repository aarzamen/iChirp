import ActivityKit
import ChirpCore
import ChirpFeatures
import Foundation

/// Keeps the dictation Live Activity in step with the coordinator (M2). It starts the moment recording begins — an
/// `AudioRecordingIntent` requires one while recording, or iOS stops it — shows Paused and Finishing, and ends after
/// the outcome (Copied / Not copied stays a few seconds; a discard ends it at once). Without Live Activities allowed
/// (Settings → Parakeet → Live Activities off) dictation still works in the app.
@MainActor final class DictationLiveActivity {
    private var activity: Activity<DictationActivityAttributes>?
    private let modelName: String
    private let logger = Log.logger("live-activity")

    init(modelName: String) {
        self.modelName = modelName
    }

    func update(for state: DictationFlowState, recordedSeconds: TimeInterval) {
        let timerStart = Date().addingTimeInterval(-recordedSeconds)
        switch state {
        case .recording:
            show(.init(phase: .recording, timerStart: timerStart, detail: nil))
        case .paused:
            show(.init(phase: .paused, timerStart: timerStart, detail: "A call or Siri has the microphone"))
        case .stopping, .pendingStop:
            show(.init(phase: .finishing, timerStart: timerStart, detail: "Transcribing on this iPhone"))
        case .done:
            end(.init(phase: .copied, timerStart: timerStart, detail: "Copied to your clipboard"), after: 5)
        case .failed(let message):
            end(.init(phase: .failed, timerStart: timerStart, detail: message), after: 8)
        case .cancelled, .idle:
            end(nil, after: 0)
        case .starting:
            break
        }
    }

    private func show(_ state: DictationActivityAttributes.ContentState) {
        let content = ActivityContent(state: state, staleDate: nil)
        if let activity {
            // ActivityKit's `Activity` is not marked Sendable; it is only ever used from this main-actor owner.
            nonisolated(unsafe) let current = activity
            Task { await current.update(content) }
            return
        }
        // Only a recording starts one: a Finishing update after the app was relaunched has nothing to show.
        guard state.phase == .recording, ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        do {
            activity = try Activity.request(
                attributes: DictationActivityAttributes(modelName: modelName), content: content, pushType: nil)
            logger.notice("live_activity_started")
        } catch {
            logger.error("live_activity_failed error_type=\(String(describing: type(of: error)), privacy: .public)")
        }
    }

    private func end(_ state: DictationActivityAttributes.ContentState?, after seconds: TimeInterval) {
        guard let activity else { return }
        self.activity = nil
        let content = state.map { ActivityContent(state: $0, staleDate: nil) }
        let policy: ActivityUIDismissalPolicy = seconds > 0 ? .after(Date().addingTimeInterval(seconds)) : .immediate
        nonisolated(unsafe) let ending = activity
        Task { await ending.end(content, dismissalPolicy: policy) }
    }
}
