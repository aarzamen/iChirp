import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

/// The dictation Live Activity: state, recorded time and Stop on the Lock Screen and in the Dynamic Island.
struct DictationLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DictationActivityAttributes.self) { context in
            LockScreenView(state: context.state, modelName: context.attributes.modelName)
                .activityBackgroundTint(Color(hex: DictationActivityPalette.nightHex))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    PhaseLabel(state: context.state)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    ElapsedText(state: context.state)
                        .font(.system(size: 22, weight: .bold))
                        .monospacedDigit()
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if context.state.phase == .recording || context.state.phase == .paused {
                        StopButton()
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
                ElapsedText(state: context.state)
                    .monospacedDigit()
                    .frame(maxWidth: 44)
            } minimal: {
                Image(systemName: context.state.phase.symbol)
                    .foregroundStyle(context.state.phase.tint)
            }
            .keylineTint(Color(hex: DictationActivityPalette.dictationAccentHex))
        }
    }
}

private struct LockScreenView: View {
    let state: DictationActivityAttributes.ContentState
    let modelName: String

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                PhaseLabel(state: state)
                Text(state.detail ?? "\(modelName) · on device")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.72))
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            if state.phase == .recording || state.phase == .paused {
                ElapsedText(state: state)
                    .font(.system(size: 26, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .frame(maxWidth: 80, alignment: .trailing)
                StopButton()
            }
        }
        .padding(16)
    }
}

private struct PhaseLabel: View {
    let state: DictationActivityAttributes.ContentState

    var body: some View {
        Label(state.phase.title, systemImage: state.phase.symbol)
            .font(.system(size: 15, weight: .bold))
            .foregroundStyle(state.phase.tint)
    }
}

/// Recorded time while recording; frozen (not counting) otherwise.
private struct ElapsedText: View {
    let state: DictationActivityAttributes.ContentState

    var body: some View {
        if state.phase == .recording {
            Text(timerInterval: state.timerStart...Date.distantFuture, countsDown: false)
        } else {
            let seconds = max(0, Int(Date().timeIntervalSince(state.timerStart)))
            Text(String(format: "%d:%02d", seconds / 60, seconds % 60))
        }
    }
}

private struct StopButton: View {
    var body: some View {
        Button(intent: StopDictationIntent()) {
            Label("Stop & copy", systemImage: "stop.fill")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
        }
        .tint(Color(hex: DictationActivityPalette.accentHex))
        .accessibilityHint("Stops, transcribes the recording and copies the text.")
    }
}

extension DictationActivityAttributes.ContentState.Phase {
    var title: String {
        switch self {
        case .recording: "Dictating"
        case .paused: "Paused"
        case .finishing: "Finishing"
        case .copied: "Copied"
        case .failed: "Not copied"
        }
    }

    var symbol: String {
        switch self {
        case .recording: "waveform"
        case .paused: "pause.fill"
        case .finishing: "text.badge.checkmark"
        case .copied: "checkmark.circle.fill"
        case .failed: "exclamationmark.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .recording: Color(hex: DictationActivityPalette.recordRedHex)
        case .copied: Color(hex: DictationActivityPalette.successHex)
        default: Color(hex: DictationActivityPalette.dictationAccentHex)
        }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255)
    }
}
