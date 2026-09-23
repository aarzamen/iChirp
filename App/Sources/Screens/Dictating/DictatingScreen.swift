import ChirpCore
import ChirpFeatures
import ChirpUI
import SwiftUI
import UIKit

/// The full-screen dictation surface (canvas `Dictating.dc.html`, night background): status row, live text (settled
/// words bright, the still-forming tail dimmed, a coral caret), a waveform from the real input level, the timer, and
/// Cancel / Stop & copy / Polish after.
///
/// The live text is only a preview. What lands on the clipboard is the final Parakeet pass over the recording, shown
/// here after "Copied" (plan 011's rule). Every state is real: the timer counts recorded audio, the waveform draws the
/// microphone's level, and the finishing bar is the engine's own progress.
struct DictatingScreen: View {
    @Environment(AppEnvironment.self) private var environment
    let openTab: (AppTab) -> Void

    private var dictation: DictationCoordinator { environment.dictation }

    var body: some View {
        VStack(spacing: 0) {
            statusRow
            DictationVoiceCommandBar()  // M6: voice-command chip (display only) and what the final pass applied
                .padding(.top, 12)
            Spacer(minLength: 16)
            VStack(spacing: 30) {
                centerContent
                if showsMeter {
                    Waveform(levels: dictation.levels, isLive: dictation.state == .recording)
                        .frame(height: 64)
                    timer
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
    }

    // MARK: - Status row

    private var statusRow: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(statusDotColor)
                .frame(width: 9, height: 9)
                .accessibilityHidden(true)
            Text(statusTitle)
                .font(.system(size: 12.5, weight: .bold))
                .tracking(1.25)
                .textCase(.uppercase)
                .foregroundStyle(.white.opacity(0.72))
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            Text("\(modelName) · on device")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.82))
                .padding(.horizontal, 11)
                .frame(height: 26)
                .background(Capsule().fill(.white.opacity(0.10)))
        }
        .frame(minHeight: 30)
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

    /// Settled words at 94% white, the tentative tail at 42%, then the coral caret.
    private func liveText(dimmed: Bool) -> some View {
        let committed = dictation.committedText
        let tentative = dictation.tentativeText
        let isEmpty = committed.isEmpty && tentative.isEmpty
        var text = Text(committed).foregroundStyle(.white.opacity(dimmed ? 0.6 : 0.94))
        if !tentative.isEmpty {
            text = text + Text(committed.isEmpty ? tentative : " " + tentative).foregroundStyle(.white.opacity(0.42))
        }
        return Group {
            if isEmpty {
                Text(dictation.state == .recording ? "Listening…" : " ")
                    .foregroundStyle(.white.opacity(0.42))
            } else {
                text + Text(dimmed ? "" : " ▍").foregroundStyle(Tokens.Color.dictationAccent)
            }
        }
        .font(.system(size: 19))
        .lineSpacing(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .lineLimit(8)
        .truncationMode(.head)
        .accessibilityLabel(isEmpty ? "Listening" : "Live preview: \(committed) \(tentative)")
        .accessibilityHint("A preview only. The copied text comes from the final pass.")
    }

    private var finishingProgress: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Transcribing the recording on this iPhone")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white.opacity(0.82))
            ProgressView(value: dictation.finalPassProgress ?? 0)
                .tint(Tokens.Color.dictationAccent)
            if dictation.isBusyNoticeVisible {
                Text("Still finishing the last dictation.")
                    .font(.system(size: 12.5))
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
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white.opacity(0.9))
            .fixedSize(horizontal: false, vertical: true)
            if let error = dictation.resumeError {
                Text(error)
                    .font(.system(size: 13))
                    .foregroundStyle(Tokens.Color.dictationAccent)
            }
            if pause == .waitingForResume {
                Button {
                    dictation.resume()
                } label: {
                    Label("Resume", systemImage: "mic.fill")
                        .font(.system(size: 15, weight: .bold))
                        .padding(.horizontal, 18)
                        .frame(minHeight: 44)
                        .background(Capsule().fill(Tokens.Color.accent))
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var finalText: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Copied to your clipboard", systemImage: "checkmark.circle.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Tokens.Color.success)
            ScrollView {
                Text(dictation.copiedText ?? "")
                    .font(.system(size: 19))
                    .lineSpacing(10)
                    .foregroundStyle(.white.opacity(0.94))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 320)
            Text("Paste it anywhere. It is also saved in your Library.")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.72))
        }
        .accessibilityElement(children: .combine)
    }

    private func failure(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Nothing was copied", systemImage: "exclamationmark.circle.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Tokens.Color.dictationAccent)
            Text(message)
                .font(.system(size: 17))
                .foregroundStyle(.white.opacity(0.94))
                .fixedSize(horizontal: false, vertical: true)
            if dictation.canRetry {
                Text("The recording is kept in your Library.")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.72))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Timer

    private var timer: some View {
        let seconds = dictation.elapsedLabelSeconds
        return Text(String(format: "%d:%02d", seconds / 60, seconds % 60))
            .font(.system(size: 44, weight: .bold))
            .monospacedDigit()
            .tracking(0.4)
            .foregroundStyle(.white.opacity(dictation.state == .recording ? 1 : 0.6))
            .accessibilityLabel("\(seconds) seconds recorded")
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
                    .font(.system(size: 12.5))
                    .lineSpacing(3)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white.opacity(0.72))
                    .padding(.top, 26)
            }
        }
    }

    private var footerText: String {
        (dictation.polishAfter ? "Clean text" : "Your text")
            + " lands on your clipboard. Audio and transcript never leave this iPhone."
    }

    private func failureSecondary(_ message: String) -> (String, () -> Void)? {
        if message == FileTranscriptionPipeline.modelMissingMessage {
            return (
                "Open Settings",
                {
                    dictation.dismiss()
                    openTab(.settings)
                }
            )
        }
        if message == AudioCaptureError.microphonePermissionDenied.errorDescription {
            return (
                "Allow microphone",
                {
                    dictation.dismiss()
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
            )
        }
        return dictation.canRetry ? ("Close", { dictation.dismiss() }) : nil
    }

    private func outcomeButtons(primary: (String, () -> Void), secondary: (String, () -> Void)?) -> some View {
        VStack(spacing: 12) {
            Button(action: primary.1) {
                Text(primary.0)
                    .font(.system(size: 17, weight: .bold))
                    .frame(maxWidth: .infinity, minHeight: 54)
                    .background(Capsule().fill(Tokens.Color.accent))
            }
            .buttonStyle(.plain)
            if let secondary {
                Button(action: secondary.1) {
                    Text(secondary.0)
                        .font(.system(size: 16, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .background(Capsule().fill(.white.opacity(0.10)))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.bottom, 12)
    }

    private var controls: some View {
        HStack(alignment: .bottom, spacing: 34) {
            circleControl(label: "Cancel", size: 62, fill: .white.opacity(0.10), stroke: .clear) {
                Image(systemName: "xmark")
                    .font(.system(size: 22, weight: .semibold))
            } action: {
                dictation.cancel()
            }
            .accessibilityHint("Discards this dictation. Nothing is saved.")

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
                Text(label)
                    .font(.system(size: 11.5, weight: glow ? .bold : .semibold))
                    .foregroundStyle(glow ? .white : labelColor)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
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
