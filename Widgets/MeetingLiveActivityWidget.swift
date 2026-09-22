import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

/// The meeting Live Activity (M3): state, recorded time, Pause/Resume and Stop & save on the Lock Screen and in the
/// Dynamic Island.
struct MeetingLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: MeetingActivityAttributes.self) { context in
            MeetingLockScreenView(state: context.state, title: context.attributes.title)
                .activityBackgroundTint(Color(hex: MeetingActivityPalette.coverNightHex))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    MeetingPhaseLabel(phase: context.state.phase)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    MeetingElapsedText(state: context.state)
                        .font(.system(size: 22, weight: .bold))
                        .monospacedDigit()
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if context.state.phase.isOpen {
                        MeetingButtons(phase: context.state.phase)
                    } else if let detail = context.state.detail {
                        Text(detail)
                            .font(.system(size: 13))
                            .foregroundStyle(.white.opacity(0.8))
                            .lineLimit(2)
                    }
                }
            } compactLeading: {
                Image(systemName: context.state.phase.symbol)
                    .foregroundStyle(context.state.phase.tint)
            } compactTrailing: {
                MeetingElapsedText(state: context.state)
                    .monospacedDigit()
                    .frame(maxWidth: 52)
            } minimal: {
                Image(systemName: context.state.phase.symbol)
                    .foregroundStyle(context.state.phase.tint)
            }
            .keylineTint(Color(hex: MeetingActivityPalette.rosetteHex))
        }
    }
}

private struct MeetingLockScreenView: View {
    let state: MeetingActivityAttributes.ContentState
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    MeetingPhaseLabel(phase: state.phase)
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                MeetingElapsedText(state: state)
                    .font(.system(size: 28, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 120, alignment: .trailing)
            }
            if let detail = state.detail {
                Text(detail)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(2)
            }
            if state.phase.isOpen {
                MeetingButtons(phase: state.phase)
            }
        }
        .padding(16)
    }
}

private struct MeetingPhaseLabel: View {
    let phase: MeetingActivityAttributes.ContentState.Phase

    var body: some View {
        Label(phase.title, systemImage: phase.symbol)
            .font(.system(size: 15, weight: .bold))
            .foregroundStyle(phase.tint)
    }
}

/// Recorded time: counting while recording, frozen otherwise.
private struct MeetingElapsedText: View {
    let state: MeetingActivityAttributes.ContentState

    var body: some View {
        if state.phase == .recording {
            Text(timerInterval: state.timerStart...Date.distantFuture, countsDown: false)
        } else {
            let seconds = max(0, state.recordedSeconds)
            Text(
                seconds >= 3_600
                    ? String(format: "%d:%02d:%02d", seconds / 3_600, seconds / 60 % 60, seconds % 60)
                    : String(format: "%d:%02d", seconds / 60, seconds % 60))
        }
    }
}

private struct MeetingButtons: View {
    let phase: MeetingActivityAttributes.ContentState.Phase

    var body: some View {
        HStack(spacing: 10) {
            Button(intent: ToggleMeetingPauseIntent()) {
                Label(
                    phase == .recording ? "Pause" : "Resume",
                    systemImage: phase == .recording ? "pause.fill" : "play.fill"
                )
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
            }
            .tint(.white.opacity(0.2))
            Button(intent: StopMeetingIntent()) {
                Label("Stop & save", systemImage: "stop.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
            }
            .tint(Color(hex: MeetingActivityPalette.stopRedHex))
            .accessibilityHint("Stops recording and transcribes the meeting on this iPhone.")
        }
    }
}

extension MeetingActivityAttributes.ContentState.Phase {
    /// Recording, paused or interrupted: the buttons show.
    var isOpen: Bool {
        switch self {
        case .recording, .paused, .interrupted: true
        case .finishing, .saved, .failed: false
        }
    }

    var title: String {
        switch self {
        case .recording: "Recording"
        case .paused: "Paused"
        case .interrupted: "Interrupted"
        case .finishing: "Transcribing"
        case .saved: "Saved"
        case .failed: "Not transcribed"
        }
    }

    var symbol: String {
        switch self {
        case .recording: "record.circle"
        case .paused: "pause.fill"
        case .interrupted: "phone.fill"
        case .finishing: "text.badge.checkmark"
        case .saved: "checkmark.circle.fill"
        case .failed: "exclamationmark.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .recording: Color(hex: MeetingActivityPalette.recordRedHex)
        case .saved: Color(hex: MeetingActivityPalette.rosetteHex)
        default: .white.opacity(0.85)
        }
    }
}
