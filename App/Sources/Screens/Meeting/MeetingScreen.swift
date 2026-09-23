import ChirpCore
import ChirpFeatures
import ChirpUI
import SwiftUI

/// The Meeting screen (canvas `Meeting.dc.html`): header with "Hide recording", the recording card (rosette, state,
/// "Microphone · saving on this iPhone", timer, the microphone level), Notes / Live transcript tabs, and Mute /
/// Pause / Stop & save. Then Finishing (the final pass's real progress), Saved (opens the transcript) or a failure
/// with Retry.
///
/// Every state is real: the timer counts recorded audio, the meter draws the microphone's level, the live text comes
/// from Parakeet passes over the recorded chunks (display-only), and the progress bar is the engine's own. The
/// canvas's "Room" meter is not drawn: an iPhone has no second source for it (plan 012 Step 7, handoff).
struct MeetingScreen: View {
    @Environment(AppEnvironment.self) private var environment
    /// Called with the saved meeting's id when the person opens its transcript.
    let openTranscript: (UUID) -> Void

    @State private var tab: Tab = .notes
    @State private var confirmDiscard = false
    @FocusState private var notesFocused: Bool

    enum Tab: Hashable { case notes, transcript }

    private var meeting: MeetingCoordinator { environment.meeting }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    recordingCard
                    if let warning = meeting.storageWarning, meeting.state.isCapturing {
                        notice(warning, systemImage: "externaldrive.badge.exclamationmark")
                    }
                    stateContent
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.interactively)
            bottomBar
        }
        .background(Tokens.Color.ground.ignoresSafeArea())
        .confirmationDialog(
            "Discard this meeting?", isPresented: $confirmDiscard, titleVisibility: .visible
        ) {
            Button("Discard recording and notes", role: .destructive) { meeting.discard() }
            Button("Keep recording", role: .cancel) {}
        } message: {
            Text("The audio and your notes are deleted from this iPhone. This cannot be undone.")
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Button {
                if meeting.state.isCapturing || meeting.state == .stopping {
                    meeting.isScreenHidden = true
                } else {
                    meeting.dismiss()
                }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Tokens.Color.ink)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(meeting.state.isCapturing ? "Hide recording" : "Close")
            .accessibilityHint(meeting.state.isCapturing ? "Recording continues. Return from Capture." : "")
            VStack(alignment: .leading, spacing: 1) {
                Text(meeting.displayName.isEmpty ? "Meeting" : meeting.displayName)
                    .chirpFont(17, .bold)
                    .foregroundStyle(Tokens.Color.ink)
                    .lineLimit(1)
                Text(subtitle)
                    .chirpFont(12.5)
                    .foregroundStyle(Tokens.Color.secondary)
                    .lineLimit(1)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            if meeting.state.isCapturing || meeting.state == .starting {
                Menu {
                    Button("Discard meeting…", systemImage: "trash", role: .destructive) { confirmDiscard = true }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Tokens.Color.ink)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("More options")
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 52)
    }

    private var subtitle: String {
        if meeting.hasLivePreview {
            return meeting.usesVoiceActivity ? "Live text cuts at pauses" : "Live text every few seconds"
        }
        return meeting.state.isCapturing ? "Live text needs the speech model" : "On this iPhone"
    }

    // MARK: - Recording card

    private var recordingCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 14) {
                RosetteMark(halo: meeting.state == .recording)
                    .frame(width: 46, height: 54)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        Circle()
                            .fill(stateDotColor)
                            .frame(width: 9, height: 9)
                            .accessibilityHidden(true)
                        Text(stateTitle)
                            .chirpFont(15, .bold)
                            .foregroundStyle(Tokens.Color.ink)
                    }
                    Text(sourceLine)
                        .chirpFont(12.5)
                        .foregroundStyle(Tokens.Color.secondary)
                }
                Spacer(minLength: 8)
                Text(Formatting.clock(ms: Int(meeting.recordedSeconds * 1000)))
                    .chirpTitleFont(26, .heavy)
                    .monospacedDigit()
                    .foregroundStyle(Tokens.Color.ink)
                    .accessibilityLabel("Recorded \(Formatting.duration(ms: Int(meeting.recordedSeconds * 1000)))")
            }
            if meeting.state.isCapturing || meeting.state == .starting {
                LevelMeter(
                    label: "Mic", levels: meeting.levels, isLive: meeting.state == .recording && !meeting.isMuted)
            }
        }
        .padding(16)
        .background(CardBackground(radius: Tokens.Radius.l))
        .accessibilityElement(children: .contain)
    }

    /// What the microphone is doing, in one line (the canvas's "Mic + room audio" corrected to the real source).
    private var sourceLine: String {
        switch meeting.state {
        case .paused: "Paused · nothing is recorded"
        case .interrupted: "Interrupted · everything so far is saved"
        case .waitingForResume: "Stopped · everything so far is saved"
        case .stopping, .saved, .failed: "Recording saved on this iPhone"
        default: meeting.isMuted ? "Muted · silence is recorded" : "Microphone · saving on this iPhone"
        }
    }

    private var stateTitle: String {
        switch meeting.state {
        case .idle, .starting: "Starting"
        case .recording: "Recording"
        case .paused: "Paused"
        case .interrupted: "Interrupted"
        case .waitingForResume: "Microphone stopped"
        case .stopping: "Transcribing"
        case .saved: "Saved"
        case .failed: "Not transcribed"
        }
    }

    private var stateDotColor: Color {
        switch meeting.state {
        case .recording: meeting.isMuted ? Tokens.Color.secondary : Tokens.Color.recordRed
        case .saved: Tokens.Color.success
        case .failed, .waitingForResume, .interrupted: Tokens.Color.accent
        default: Tokens.Color.mutedText
        }
    }

    // MARK: - Content by state

    @ViewBuilder private var stateContent: some View {
        switch meeting.state {
        case .interrupted:
            notice(
                "A call, Siri or an alarm has the microphone. Recording resumes by itself afterwards; everything so "
                    + "far is saved.", systemImage: "phone.fill")
            tabs
        case .waitingForResume:
            notice(
                meeting.captureProblem ?? "The microphone is free again. Tap Resume to keep recording, or Stop & save.",
                systemImage: "mic.slash")
            tabs
        case .stopping:
            finishing
        case .saved(let id):
            saved(id)
        case .failed(let message, let id):
            failure(message, id: id)
        default:
            tabs
        }
    }

    private var tabs: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("View", selection: $tab) {
                Text("Notes").tag(Tab.notes)
                Text("Live transcript").tag(Tab.transcript)
            }
            .pickerStyle(.segmented)
            switch tab {
            case .notes: notesEditor
            case .transcript: liveTranscript
            }
        }
    }

    private var notesEditor: some View {
        @Bindable var meeting = environment.meeting
        return VStack(alignment: .leading, spacing: 6) {
            TextEditor(text: $meeting.notes)
                .focused($notesFocused)
                .chirpFont(15)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 180)
                .padding(10)
                .background(CardBackground(radius: Tokens.Radius.s))
                .overlay(alignment: .topLeading) {
                    if meeting.notes.isEmpty {
                        Text("Agenda, decisions, action items…")
                            .chirpFont(15)
                            .foregroundStyle(Tokens.Color.mutedText)
                            .padding(.horizontal, 15)
                            .padding(.vertical, 18)
                            .allowsHitTesting(false)
                    }
                }
                .accessibilityLabel("Meeting notes")
            Text("Saved with the recording as you type, and kept with the transcript.")
                .chirpFont(12)
                .foregroundStyle(Tokens.Color.secondary)
        }
    }

    @ViewBuilder private var liveTranscript: some View {
        VStack(alignment: .leading, spacing: 12) {
            if meeting.isLiveLagging {
                notice(
                    "Live text is behind; the saved transcript will still cover everything.", systemImage: "hourglass")
            }
            if !meeting.hasLivePreview {
                // Review N6: name the live route's engine, the same way the Capture banner does — it may not be
                // Parakeet (a restored backup, or a revoked Apple Speech permission).
                let engine = meeting.liveSpeechEngine
                Text(
                    engine.isParakeet
                        ? "No live text: the Parakeet speech model is not on this iPhone yet. The meeting is still "
                            + "recorded and transcribed after you download it (Settings → Speech)."
                        : "No live text: \(engine.name) isn’t ready on this iPhone (Settings → Speech engines). The "
                            + "meeting is still recorded and transcribed after you fix that."
                )
                .chirpFont(14)
                .foregroundStyle(Tokens.Color.secondary)
            } else if meeting.liveParagraphs.isEmpty {
                Text(
                    "Live text appears a few seconds after people speak. It is a preview; the saved transcript comes "
                        + "from a full pass when you stop."
                )
                .chirpFont(14)
                .foregroundStyle(Tokens.Color.secondary)
            } else {
                ForEach(meeting.liveParagraphs) { paragraph in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(Formatting.clock(ms: paragraph.startMs))
                            .chirpFont(12, .semibold)
                            .monospacedDigit()
                            .foregroundStyle(Tokens.Color.secondary)
                        Text(paragraph.text)
                            .chirpFont(15.5)
                            .foregroundStyle(Tokens.Color.ink)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private var finishing: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Transcribing the whole meeting on this iPhone, then finding who spoke when.")
                .chirpFont(15)
                .foregroundStyle(Tokens.Color.ink)
                .fixedSize(horizontal: false, vertical: true)
            ProgressView(value: meeting.finalPassProgress ?? 0)
                .tint(Tokens.Color.accent)
            Text("\(Formatting.percent(meeting.finalPassProgress ?? 0))%")
                .chirpFont(12.5, .semibold)
                .monospacedDigit()
                .foregroundStyle(Tokens.Color.secondary)
            Text(
                "The recording is saved. You can leave this screen; the meeting appears in the Library when it is done."
            )
            .chirpFont(12.5)
            .foregroundStyle(Tokens.Color.secondary)
        }
        .padding(16)
        .background(CardBackground(radius: Tokens.Radius.s))
    }

    private func saved(_ id: UUID) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Transcript saved with speakers and your notes.", systemImage: "checkmark.circle.fill")
                .chirpFont(15, .semibold)
                .foregroundStyle(Tokens.Color.ink)
            Button {
                openTranscript(id)
            } label: {
                CapsuleButtonLabel(title: "Open transcript", kind: .filled)
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CardBackground(radius: Tokens.Radius.s))
    }

    private func failure(_ message: String, id: UUID?) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .chirpFont(15, .semibold)
                .foregroundStyle(Tokens.Color.ink)
                .fixedSize(horizontal: false, vertical: true)
            if id != nil {
                Text("The recording and your notes are kept. Retry here or later from the Library.")
                    .chirpFont(12.5)
                    .foregroundStyle(Tokens.Color.secondary)
                HStack(spacing: 10) {
                    Button {
                        meeting.retry()
                    } label: {
                        CapsuleButtonLabel(title: "Retry", kind: .filled)
                    }
                    .buttonStyle(.plain)
                    Button {
                        meeting.dismiss()
                    } label: {
                        CapsuleButtonLabel(title: "Close", kind: .tinted)
                    }
                    .buttonStyle(.plain)
                }
            } else {
                Button {
                    meeting.dismiss()
                } label: {
                    CapsuleButtonLabel(title: "Close", kind: .filled)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CardBackground(radius: Tokens.Radius.s))
    }

    private func notice(_ text: String, systemImage: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(AppColor.accentText)
                .accessibilityHidden(true)
            Text(text)
                .chirpFont(13.5)
                .foregroundStyle(Tokens.Color.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CardBackground(radius: Tokens.Radius.s, fill: Tokens.Color.surface, stroke: AppColor.tintStroke))
        .accessibilityElement(children: .combine)
    }

    // MARK: - Bottom bar

    @ViewBuilder private var bottomBar: some View {
        if meeting.state.isCapturing || meeting.state == .starting {
            HStack(spacing: 10) {
                smallButton(
                    meeting.isMuted ? "Unmute" : "Mute", systemImage: meeting.isMuted ? "mic.slash.fill" : "mic.fill"
                ) { meeting.toggleMute() }
                .accessibilityHint("Muted time is recorded as silence.")
                if meeting.state == .paused || meeting.state == .waitingForResume {
                    smallButton("Resume", systemImage: "play.fill") { meeting.resume() }
                } else {
                    smallButton("Pause", systemImage: "pause.fill") { meeting.pause() }
                        .disabled(meeting.state != .recording)
                        .accessibilityHint("Nothing is recorded until you resume.")
                }
                Button {
                    notesFocused = false
                    meeting.stop()
                } label: {
                    Label("Stop & save", systemImage: "stop.fill")
                        .chirpFont(16, .bold)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, minHeight: 56)
                        .background(Capsule().fill(Tokens.Color.stopRed))
                }
                .buttonStyle(.plain)
                .disabled(!meeting.state.isCapturing)
                .accessibilityHint("Stops recording and transcribes the meeting on this iPhone.")
            }
            .padding(.horizontal, 20)
            .padding(.top, 10)
            .padding(.bottom, 8)
            .background(Tokens.Color.ground)
        }
    }

    /// A compact round-cornered button: icon over a short label (Mute, Pause, Resume).
    private func smallButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: systemImage)
                    .font(.system(size: 17, weight: .semibold))
                Text(title)
                    .chirpFont(12, .semibold)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(Tokens.Color.ink)
            .frame(width: 78, height: 56)
            .background(CardBackground(radius: 18))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
    }
}

/// A horizontal level meter from the recorder's real input levels ("Mic"), green on a quiet track.
private struct LevelMeter: View {
    let label: String
    let levels: [Float]
    let isLive: Bool

    var body: some View {
        HStack(spacing: 10) {
            Text(label)
                .chirpFont(12, .semibold)
                .foregroundStyle(Tokens.Color.secondary)
                .frame(width: 30, alignment: .leading)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(AppColor.quietFill)
                    Capsule()
                        .fill(Tokens.Color.rosette)
                        .frame(width: proxy.size.width * CGFloat(isLive ? min(max(levels.last ?? 0, 0), 1) : 0))
                }
            }
            .frame(height: 8)
            .animation(.easeOut(duration: 0.12), value: levels.count)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Microphone level")
        .accessibilityValue(isLive ? "\(Int((levels.last ?? 0) * 100)) percent" : "Not recording")
    }
}
