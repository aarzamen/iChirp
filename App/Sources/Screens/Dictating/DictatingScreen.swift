import ChirpCore
import ChirpFeatures
import ChirpUI
import SwiftUI
import UIKit

/// The full-screen dictation surface (canvas `Dictating.dc.html`, night background): status row, live text (settled
/// words bright, the still-forming tail dimmed, a coral caret), a waveform from the real input level, the timer, and
/// Cancel / Stop & copy / Polish after.
///
/// Every text follows Dynamic Type (`chirpFont`; the timer grows up to AX1), and the layout tightens at accessibility
/// sizes (status row stacks, fewer live-text lines, control labels wrap). Cancel discards a false start at once and
/// asks first once more than a few seconds are recorded (`DictationDiscardPrompt`, UX audit F72).
///
/// The live text is only a preview. What lands on the clipboard is the final Parakeet pass over the recording, shown
/// here after "Copied" (plan 011's rule). Every state is real: the timer counts recorded audio, the waveform draws the
/// microphone's level, and the finishing bar is the engine's own progress.
struct DictatingScreen: View {
    @Environment(AppEnvironment.self) private var environment
    let openTab: (AppTab) -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// The question Cancel is asking, while it is up (F72).
    @State private var discardPrompt: DictationDiscardPrompt?

    private var dictation: DictationCoordinator { environment.dictation }

    var body: some View {
        VStack(spacing: 0) {
            statusRow
            DictationVoiceCommandBar()  // M6: voice-command chip (display only) and what the final pass applied
                .padding(.top, 12)
            if let next = environment.create.speechOutputTitle {  // plan 022: this dictation feeds a Create chain
                CreateNextChip(title: next)
                    .padding(.top, 10)
            }
            Spacer(minLength: 16)
            VStack(spacing: dynamicTypeSize.isAccessibilitySize ? 18 : 30) {
                centerContent
                if showsMeter {
                    Waveform(levels: dictation.levels, isLive: dictation.state == .recording)
                        .frame(height: dynamicTypeSize.isAccessibilitySize ? 44 : 64)
                    DictationTimer(
                        seconds: dictation.elapsedLabelSeconds, isLive: dictation.state == .recording
                    )
                    // Big already: it grows with the text size up to AX1, then stops.
                    .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                }
            }
            Spacer(minLength: 16)
            bottomArea
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Tokens.Color.night.ignoresSafeArea())
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
        .statusBarHidden(false)
        .dictationVoiceCommandSheets(environment: environment)  // M6: "send to SOAP / Transform" after the copy
        .confirmationDialog(
            discardPrompt?.title ?? "",
            isPresented: Binding(get: { discardPrompt != nil }, set: { if !$0 { discardPrompt = nil } }),
            titleVisibility: .visible,
            presenting: discardPrompt
        ) { prompt in
            Button(prompt.discardTitle, role: .destructive) {
                // The explicit discard, unchanged; skipped if the dictation ended while the question was up.
                if DictationDiscardPrompt.canDiscard(in: dictation.state) { dictation.cancel() }
            }
            Button(prompt.keepTitle, role: .cancel) {}
        } message: { prompt in
            Text(prompt.message)
        }
        .onChange(of: dictation.state) { _, state in
            // A dictation that ended meanwhile (Lock Screen Stop & copy, a failure) has nothing left to discard.
            if discardPrompt != nil, !DictationDiscardPrompt.canDiscard(in: state) { discardPrompt = nil }
        }
    }

    /// Cancel: a false start goes at once; a longer dictation asks first (F72).
    private func requestCancel() {
        if let prompt = DictationDiscardPrompt.forCancel(
            state: dictation.state, recordedSeconds: dictation.recordedSeconds)
        {
            discardPrompt = prompt
        } else {
            dictation.cancel()
        }
    }

    private var cancelHint: String {
        dictation.recordedSeconds >= DictationDiscardPrompt.confirmAfterSeconds
            ? "Asks first, then discards this dictation. Nothing is saved."
            : "Discards this dictation. Nothing is saved."
    }

    // MARK: - Status row

    /// The state and the engine chip side by side; stacked at accessibility sizes so neither is squeezed.
    private var statusRow: some View {
        let layout =
            dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(spacing: 10))
        return layout {
            HStack(spacing: 10) {
                Circle()
                    .fill(statusDotColor)
                    .frame(width: 9, height: 9)
                    .accessibilityHidden(true)
                Text(statusTitle)
                    .chirpFont(12.5, .bold)
                    .tracking(1.25)
                    .textCase(.uppercase)
                    .foregroundStyle(.white.opacity(0.72))
                    .accessibilityAddTraits(.isHeader)
            }
            if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 8) }
            Text("\(modelName) · on device")
                .chirpFont(11.5, .semibold)
                .foregroundStyle(.white.opacity(0.82))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 11)
                .padding(.vertical, 4)
                .frame(minHeight: 26)
                .background(Capsule().fill(.white.opacity(0.10)))
        }
        .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
    }

    /// M7: the engine that writes the kept text (the final route); Parakeet unless Settings → Speech engines says so.
    private var modelName: String {
        environment.speechEngines.row(for: .final)?.capabilities.displayName
            ?? (environment.runningVariant == .v3 ? "Parakeet v3" : "Parakeet v2")
    }

    private var statusTitle: String {
        switch dictation.state {
        case .idle, .starting: "Starting"
        case .recording: "Dictating"
        case .paused: "Paused"
        case .pendingStop, .stopping: "Finishing"
        case .done: "Copied"
        case .failed: "Not copied"
        case .cancelled: "Discarded"
        }
    }

    private var statusDotColor: Color {
        switch dictation.state {
        case .recording: Tokens.Color.recordRed
        case .done: Tokens.Color.success
        case .paused, .failed: Tokens.Color.dictationAccent
        default: .white.opacity(0.4)
        }
    }

    private var showsMeter: Bool {
        switch dictation.state {
        case .starting, .recording, .paused, .pendingStop: true
        default: false
        }
    }

    // MARK: - Center

    @ViewBuilder private var centerContent: some View {
        switch dictation.state {
        case .done:
            finalText
        case .failed(let message):
            failure(message)
        case .stopping, .pendingStop:
            VStack(alignment: .leading, spacing: 18) {
                liveText(dimmed: true)
                finishingProgress
            }
        case .paused(let pause):
            VStack(alignment: .leading, spacing: 18) {
                liveText(dimmed: true)
                pausedNotice(pause)
            }
        default:
            liveText(dimmed: false)
        }
    }

    /// Settled words at 94% white, the tentative tail at 46% (`Tokens.Color.dictationTentative`), then the coral caret.
    private func liveText(dimmed: Bool) -> some View {
        let committed = dictation.committedText
        let tentative = dictation.tentativeText
        let isEmpty = committed.isEmpty && tentative.isEmpty
        var text = Text(committed).foregroundStyle(.white.opacity(dimmed ? 0.6 : 0.94))
        if !tentative.isEmpty {
            text =
                text
                + Text(committed.isEmpty ? tentative : " " + tentative)
                .foregroundStyle(Tokens.Color.dictationTentative)
        }
        return Group {
            if isEmpty {
                Text(dictation.state == .recording ? "Listening…" : " ")
                    .foregroundStyle(Tokens.Color.dictationTentative)
            } else {
                text + Text(dimmed ? "" : " ▍").foregroundStyle(Tokens.Color.dictationAccent)
            }
        }
        .chirpFont(19)
        .lineSpacing(dynamicTypeSize.isAccessibilitySize ? 4 : 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 4 : 8)
        .truncationMode(.head)
        .accessibilityLabel(isEmpty ? "Listening" : "Live preview: \(committed) \(tentative)")
        .accessibilityHint("A preview only. The copied text comes from the final pass.")
    }

    private var finishingProgress: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Transcribing the recording on this iPhone")
                .chirpFont(14, .semibold)
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(.white.opacity(0.82))
            ProgressView(value: dictation.finalPassProgress ?? 0)
                .tint(Tokens.Color.dictationAccent)
            if dictation.isBusyNoticeVisible {
                Text("Still finishing the last dictation.")
                    .chirpFont(12.5)
                    .foregroundStyle(.white.opacity(0.72))
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func pausedNotice(_ pause: DictationPause) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(
                pause == .interrupted
                    ? "Paused — a call, Siri or an alarm has the microphone. What you said so far is kept."
                    : "Paused. Resume to keep dictating, or Stop & copy what you have."
            )
            .chirpFont(15, .semibold)
            .foregroundStyle(.white.opacity(0.9))
            .fixedSize(horizontal: false, vertical: true)
            if let error = dictation.resumeError {
                Text(error)
                    .chirpFont(13)
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(Tokens.Color.dictationAccent)
            }
            if pause == .waitingForResume {
                Button {
                    dictation.resume()
                } label: {
                    Label("Resume", systemImage: "mic.fill")
                        .chirpFont(15, .bold)
                        .padding(.horizontal, 18)
                        .frame(minHeight: 44)
                        .background(Capsule().fill(Tokens.Color.accentFill))
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var finalText: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Copied to your clipboard", systemImage: "checkmark.circle.fill")
                .chirpFont(15, .semibold)
                .foregroundStyle(Tokens.Color.success)
            ScrollView {
                Text(dictation.copiedText ?? "")
                    .chirpFont(19)
                    .lineSpacing(dynamicTypeSize.isAccessibilitySize ? 4 : 10)
                    .foregroundStyle(.white.opacity(0.94))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 320)
            Text("Paste it anywhere. It is also saved in your Library.")
                .chirpFont(13)
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(.white.opacity(0.72))
        }
        .accessibilityElement(children: .combine)
    }

    private func failure(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Nothing was copied", systemImage: "exclamationmark.circle.fill")
                .chirpFont(15, .semibold)
                .foregroundStyle(Tokens.Color.dictationAccent)
            Text(message)
                .chirpFont(17)
                .foregroundStyle(.white.opacity(0.94))
                .fixedSize(horizontal: false, vertical: true)
            if dictation.canRetry {
                Text("The recording is kept in your Library.")
                    .chirpFont(13)
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(.white.opacity(0.72))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Bottom

    @ViewBuilder private var bottomArea: some View {
        switch dictation.state {
        case .done:
            outcomeButtons(primary: ("Done", { dictation.dismiss() }), secondary: nil)
        case .failed(let message):
            outcomeButtons(
                primary: dictation.canRetry
                    ? ("Retry", { dictation.retry() }) : ("Close", { dictation.dismiss() }),
                secondary: failureSecondary(message))
        case .cancelled:
            // The cover closes as soon as the discard finishes (see RootTabView).
            Color.clear.frame(height: 120)
        default:
            VStack(spacing: 0) {
                controls
                Text(footerText)
                    .chirpFont(12.5)
                    .lineSpacing(3)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white.opacity(0.72))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, dynamicTypeSize.isAccessibilitySize ? 14 : 26)
            }
        }
    }

    private var footerText: String {
        (dictation.polishAfter ? "Clean text" : "Your text")
            + " lands on your clipboard. Audio and transcript never leave this iPhone."
    }

    /// The fix for this failure, chosen by its kind (review I2), never by comparing sentences.
    private func failureSecondary(_ message: String) -> (String, () -> Void)? {
        switch dictation.failureKind {
        case .speechModelMissing:
            return (
                "Open Settings",
                {
                    dictation.dismiss()
                    openTab(.settings)
                }
            )
        case .microphoneDenied:
            return (
                "Allow microphone",
                {
                    dictation.dismiss()
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
            )
        case .other, nil:
            return dictation.canRetry ? ("Close", { dictation.dismiss() }) : nil
        }
    }

    private func outcomeButtons(primary: (String, () -> Void), secondary: (String, () -> Void)?) -> some View {
        VStack(spacing: 12) {
            Button(action: primary.1) {
                Text(primary.0)
                    .chirpFont(17, .bold)
                    .frame(maxWidth: .infinity, minHeight: 54)
                    .background(Capsule().fill(Tokens.Color.accentFill))
            }
            .buttonStyle(.plain)
            if let secondary {
                Button(action: secondary.1) {
                    Text(secondary.0)
                        .chirpFont(16, .semibold)
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .background(Capsule().fill(.white.opacity(0.10)))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.bottom, 12)
    }

    private var controls: some View {
        // Each column is its circle plus `controlLabelExtra` wide (room for the label); the spacing keeps the canvas's
        // 34 pt between circles. The circles' bottoms line up (as in the canvas) even when one label wraps.
        HStack(alignment: .circleBottom, spacing: 34 - controlLabelExtra) {
            circleControl(label: "Cancel", size: 62, fill: .white.opacity(0.10), stroke: .clear) {
                Image(systemName: "xmark")
                    .font(.system(size: 22, weight: .semibold))
            } action: {
                requestCancel()
            }
            .accessibilityHint(cancelHint)

            circleControl(label: "Stop & copy", size: 88, fill: Tokens.Color.accent, stroke: .clear, glow: true) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.white)
                    .frame(width: 30, height: 30)
            } action: {
                dictation.stop()
            }
            .disabled(dictation.state == .stopping || dictation.state == .pendingStop)
            .accessibilityHint("Stops, transcribes the recording and copies the text.")

            circleControl(
                label: "Polish after", size: 62,
                fill: dictation.polishAfter ? Tokens.Color.accent.opacity(0.22) : .white.opacity(0.10),
                stroke: dictation.polishAfter ? Tokens.Color.dictationAccent : .white.opacity(0.10),
                labelColor: dictation.polishAfter ? Tokens.Color.dictationAccent : .white.opacity(0.72)
            ) {
                Image(systemName: "sparkles")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(dictation.polishAfter ? Tokens.Color.dictationAccent : .white.opacity(0.85))
            } action: {
                dictation.polishAfter.toggle()
            }
            .accessibilityValue(dictation.polishAfter ? "On" : "Off")
            .accessibilityHint("Cleans the copied text: fillers, custom words and snippets.")
            .accessibilityAddTraits(.isToggle)
        }
    }

    /// How much wider than its circle a control's label may be: a little more at accessibility sizes, where the labels
    /// wrap to two lines.
    private var controlLabelExtra: CGFloat { dynamicTypeSize.isAccessibilitySize ? 32 : 28 }

    private func circleControl<Icon: View>(
        label: String, size: CGFloat, fill: Color, stroke: Color, glow: Bool = false,
        labelColor: Color = .white.opacity(0.72),
        @ViewBuilder icon: () -> Icon, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 9) {
                ZStack {
                    Circle()
                        .fill(fill)
                        .overlay(Circle().stroke(stroke, lineWidth: 1.5))
                        .shadow(color: glow ? Tokens.Color.accent.opacity(0.42) : .clear, radius: 12, y: 8)
                    icon()
                }
                .frame(width: size, height: size)
                .alignmentGuide(.circleBottom) { $0[.bottom] }
                // Wraps to two lines at large sizes instead of widening the row off the screen.
                Text(label)
                    .chirpFont(11.5, glow ? .bold : .semibold)
                    .foregroundStyle(glow ? .white : labelColor)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: size + controlLabelExtra)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

extension VerticalAlignment {
    /// The bottom of the Dictating screen's control circles, so they line up whatever their labels' heights.
    fileprivate enum CircleBottom: AlignmentID {
        static func defaultValue(in context: ViewDimensions) -> CGFloat { context[.bottom] }
    }

    fileprivate static let circleBottom = VerticalAlignment(CircleBottom.self)
}

/// The recorded time ("1:07"), 44 pt at the default text size and scaled with Dynamic Type (the caller caps it at
/// AX1, where it is already as large as the screen allows).
private struct DictationTimer: View {
    let seconds: Int
    let isLive: Bool
    @ScaledMetric(relativeTo: .largeTitle) private var size: CGFloat = 44

    var body: some View {
        Text(String(format: "%d:%02d", seconds / 60, seconds % 60))
            .font(.system(size: size, weight: .bold))
            .monospacedDigit()
            .tracking(0.4)
            .foregroundStyle(.white.opacity(isLive ? 1 : 0.6))
            .accessibilityLabel("\(seconds) seconds recorded")
    }
}

/// Bars from the recorder's real input levels, newest on the right; the newest few are coral while recording.
private struct Waveform: View {
    let levels: [Float]
    let isLive: Bool
    private let barCount = 29
    private let coralCount = 6

    var body: some View {
        let recent = Array(levels.suffix(barCount))
        let padded = Array(repeating: Float(0), count: barCount - recent.count) + recent
        HStack(alignment: .center, spacing: 5) {
            ForEach(Array(padded.enumerated()), id: \.offset) { index, level in
                RoundedRectangle(cornerRadius: 2)
                    .fill(
                        isLive && index >= barCount - coralCount
                            ? Tokens.Color.dictationAccent : Color.white.opacity(0.92)
                    )
                    .frame(width: 4, height: 6 + CGFloat(min(max(level, 0), 1)) * 52)
            }
        }
        .frame(maxWidth: .infinity)
        .animation(.easeOut(duration: 0.12), value: levels.count)
        .accessibilityHidden(true)
    }
}
