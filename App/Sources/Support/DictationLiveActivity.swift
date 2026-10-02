import ActivityKit
import ChirpCore
import ChirpFeatures
import Foundation

/// Keeps the dictation Live Activity in step with the coordinator (M2). It starts the moment recording begins — an
/// `AudioRecordingIntent` requires one while recording, or iOS stops it — shows Paused and Finishing, and ends after
/// the outcome (Copied / Not copied stays a few seconds; a discard ends it at once). Without Live Activities allowed
/// (Settings → Parakeet → Live Activities off) dictation still works in the app. The engine it names is read when the
/// activity starts: the Transcripts route's engine, the same one the Dictating screen shows (review M4).
///
/// Review R5-11: every update and end goes through one `LiveActivityUpdateChain`, so they reach the Lock Screen in the
/// order the states happened (independent tasks could land a quick Pause → Resume as Resume → Pause).
@MainActor final class DictationLiveActivity {
    /// What the activity does for a state (pure, so `LiveActivityContentTests` checks it without ActivityKit).
    enum Update: Equatable {
        case show(DictationActivityAttributes.ContentState)
        case end(DictationActivityAttributes.ContentState?, after: TimeInterval)
        case none
    }

    private var activity: Activity<DictationActivityAttributes>?
    private let modelName: @MainActor () -> String
    private let updates = LiveActivityUpdateChain()
    private let logger = Log.logger("live-activity")

    init(modelName: @escaping @MainActor () -> String) {
        self.modelName = modelName
    }

    func update(for state: DictationFlowState, recordedSeconds: TimeInterval, notice: String? = nil) {
        switch Self.update(for: state, recordedSeconds: recordedSeconds, notice: notice, now: Date()) {
        case .show(let content): show(content)
        case .end(let content, let seconds): end(content, after: seconds)
        case .none: break
        }
    }

    /// Review R6a-13: the recorded time travels with every state (frozen while paused), and a pause says whether a
    /// call still has the microphone or the person must tap Resume (the Dictating screen's own wording).
    ///
    /// Review R2-6 (fix round 1): `notice`, why the recording stopped on its own (the coordinator's `captureNotice`: a
    /// full disk, a microphone that could not restart), reaches the outcome here too. It takes the place of "Copied to
    /// your clipboard" (the title already says Copied) and comes before a failure's own words, so the two-line detail
    /// never cuts it off.
    static func update(
        for state: DictationFlowState, recordedSeconds: TimeInterval, notice: String? = nil, now: Date
    ) -> Update {
        let timerStart = now.addingTimeInterval(-recordedSeconds)
        func content(_ phase: DictationActivityAttributes.ContentState.Phase, _ detail: String?)
            -> DictationActivityAttributes.ContentState
        {
            .init(phase: phase, timerStart: timerStart, recordedSeconds: Int(recordedSeconds), detail: detail)
        }
        switch state {
        case .recording:
            return .show(content(.recording, nil))
        case .paused(.interrupted):
            return .show(content(.paused, "A call or Siri has the microphone"))
        case .paused(.waitingForResume):
            return .show(content(.paused, "Open Parakeet and tap Resume"))
        case .stopping, .pendingStop:
            return .show(content(.finishing, "Transcribing on this iPhone"))
        case .done:
            return .end(content(.copied, notice ?? "Copied to your clipboard"), after: 5)
        case .failed(let message):
            return .end(content(.failed, notice.map { "\($0) \(message)" } ?? message), after: 8)
        case .cancelled, .idle:
            return .end(nil, after: 0)
        case .starting:
            return .none
        }
    }

    /// Whether a state may start the activity when none is running: a capturing one. A call that takes the microphone
    /// while the dictation starts pauses it before it ever says Recording (review R5-10), so Paused starts it too
    /// (fix round 1); a Finishing update after the app was relaunched has nothing to show.
    static func startsActivity(_ phase: DictationActivityAttributes.ContentState.Phase) -> Bool {
        phase == .recording || phase == .paused
    }

    private func show(_ state: DictationActivityAttributes.ContentState) {
        let content = ActivityContent(state: state, staleDate: nil)
        if let activity {
            // ActivityKit's `Activity` is not marked Sendable; it is only ever used from this main-actor owner.
            nonisolated(unsafe) let current = activity
            updates.enqueue { await current.update(content) }
            return
        }
        guard Self.startsActivity(state.phase), ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        do {
            activity = try Activity.request(
                attributes: DictationActivityAttributes(modelName: modelName()), content: content, pushType: nil)
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
        updates.enqueue { await ending.end(content, dismissalPolicy: policy) }
    }
}

/// Runs Live Activity updates one after another, in the order they were asked for (review R5-11, the pattern of
/// `docs/solutions/concurrency/order-sensitive-commands-need-one-chained-task.md`).
@MainActor final class LiveActivityUpdateChain {
    private var tail: Task<Void, Never>?

    func enqueue(_ work: @escaping @Sendable () async -> Void) {
        let previous = tail
        tail = Task {
            await previous?.value
            await work()
        }
    }

    /// Waits for everything enqueued so far (tests).
    func drain() async {
        await tail?.value
    }
}
