import SwiftUI
import MacParakeetCore
import MacParakeetViewModels

/// Main capture screen for iOS — provides instant access to Dictation and Meeting recording
/// with real-time on-device speech transcription and dynamic waveform visualization.
public struct IOSRecordView: View {
    public enum CaptureMode: String, CaseIterable, Identifiable {
        case dictate = "Dictate"
        case meeting = "Meeting"
        public var id: String { rawValue }
    }

    @State private var coordinator = IOSLiveSpeechCoordinator.shared
    @State private var mode: CaptureMode = .dictate
    @State private var meetingNotes: String = ""
    @State private var showingErrorAlert: Bool = false
    @State private var copiedConfirmation: Bool = false

    public init() {}

    private var formattedTime: String {
        let minutes = coordinator.elapsedSeconds / 60
        let seconds = coordinator.elapsedSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    public var body: some View {
        NavigationStack {
            ZStack {
                MobileDesignSystem.Colors.background
                    .ignoresSafeArea()

                ScrollView {
                    VStack(spacing: MobileDesignSystem.Spacing.lg) {
                        // Capture Mode Picker
                        Picker("Mode", selection: $mode) {
                            ForEach(CaptureMode.allCases) { item in
                                Text(item.rawValue).tag(item)
                            }
                        }
                        .pickerStyle(.segmented)
                        .disabled(coordinator.isRecording)
                        .padding(.horizontal, MobileDesignSystem.Spacing.lg)

                        // Timer Display
                        VStack(spacing: 4) {
                            Text(formattedTime)
                                .font(MobileDesignSystem.Typography.monoTimer)
                                .foregroundColor(coordinator.isRecording ? MobileDesignSystem.Colors.accent : MobileDesignSystem.Colors.textPrimary)

                            Text(coordinator.isRecording ? (coordinator.isPaused ? "PAUSED" : "RECORDING") : "READY")
                                .font(MobileDesignSystem.Typography.monoTimestamp)
                                .foregroundColor(coordinator.isRecording ? (coordinator.isPaused ? MobileDesignSystem.Colors.warningAmber : MobileDesignSystem.Colors.errorRed) : MobileDesignSystem.Colors.textTertiary)
                                .tracking(2)

                            if copiedConfirmation {
                                Text("Copied to clipboard")
                                    .font(MobileDesignSystem.Typography.caption)
                                    .foregroundColor(MobileDesignSystem.Colors.successGreen)
                                    .transition(.opacity)
                            }
                        }
                        .padding(.top, MobileDesignSystem.Spacing.sm)

                        // Waveform Visualizer connected to real mic RMS power
                        IOSWaveformVisualizer(
                            isRecording: coordinator.isRecording && !coordinator.isPaused,
                            audioLevel: coordinator.audioLevel
                        )
                        .padding(.vertical, MobileDesignSystem.Spacing.xs)

                        // Record Action Controls
                        HStack(spacing: MobileDesignSystem.Spacing.xl) {
                            if coordinator.isRecording {
                                // Pause / Resume Button
                                Button(action: togglePause) {
                                    Image(systemName: coordinator.isPaused ? "play.fill" : "pause.fill")
                                        .font(.system(size: 22, weight: .semibold))
                                        .foregroundColor(MobileDesignSystem.Colors.textPrimary)
                                        .frame(width: 56, height: 56)
                                        .background(MobileDesignSystem.Colors.surfaceElevated)
                                        .clipShape(Circle())
                                }

                                // Stop Button
                                Button(action: stopRecording) {
                                    ZStack {
                                        Circle()
                                            .fill(MobileDesignSystem.Colors.accent)
                                            .frame(width: 84, height: 84)
                                            .shadow(color: MobileDesignSystem.Colors.accent.opacity(0.35), radius: 12, y: 6)

                                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                                            .fill(Color.white)
                                            .frame(width: 26, height: 26)
                                    }
                                }

                                // Cancel / Discard Button
                                Button(action: discardRecording) {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 20, weight: .semibold))
                                        .foregroundColor(MobileDesignSystem.Colors.errorRed)
                                        .frame(width: 56, height: 56)
                                        .background(MobileDesignSystem.Colors.surfaceElevated)
                                        .clipShape(Circle())
                                }
                            } else {
                                // Start Record Button
                                Button(action: startRecording) {
                                    ZStack {
                                        Circle()
                                            .stroke(MobileDesignSystem.Colors.accent.opacity(0.3), lineWidth: 4)
                                            .frame(width: 96, height: 96)

                                        Circle()
                                            .fill(
                                                LinearGradient(
                                                    colors: [
                                                        MobileDesignSystem.Colors.accent,
                                                        MobileDesignSystem.Colors.accentDark
                                                    ],
                                                    startPoint: .topLeading,
                                                    endPoint: .bottomTrailing
                                                )
                                            )
                                            .frame(width: 80, height: 80)
                                            .shadow(color: MobileDesignSystem.Colors.accent.opacity(0.4), radius: 16, y: 8)

                                        Image(systemName: "mic.fill")
                                            .font(.system(size: 32, weight: .semibold))
                                            .foregroundColor(.white)
                                    }
                                }
                            }
                        }
                        .padding(.vertical, MobileDesignSystem.Spacing.sm)

                        // Meeting Notes Input (When in Meeting mode)
                        if mode == .meeting {
                            VStack(alignment: .leading, spacing: 6) {
                                Label("Meeting Notes", systemImage: "note.text")
                                    .font(MobileDesignSystem.Typography.headline)
                                    .foregroundColor(MobileDesignSystem.Colors.textPrimary)

                                TextField("Type live notes, action items, or attendees...", text: $meetingNotes, axis: .vertical)
                                    .lineLimit(3...6)
                                    .padding(MobileDesignSystem.Spacing.md)
                                    .background(MobileDesignSystem.Colors.surface)
                                    .clipShape(RoundedRectangle(cornerRadius: MobileDesignSystem.CornerRadius.md))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: MobileDesignSystem.CornerRadius.md)
                                            .stroke(MobileDesignSystem.Colors.border, lineWidth: 1)
                                    )
                            }
                            .padding(.horizontal, MobileDesignSystem.Spacing.lg)
                        }

                        // Live Streaming Transcript Card
                        IOSLiveTranscriptCard(
                            text: coordinator.liveTranscript,
                            isRecording: coordinator.isRecording,
                            onCopy: {
                                PlatformPasteboard.copy(coordinator.liveTranscript)
                                copiedConfirmation = true
                                Task {
                                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                                    copiedConfirmation = false
                                }
                            }
                        )
                        .padding(.horizontal, MobileDesignSystem.Spacing.lg)
                    }
                    .padding(.vertical, MobileDesignSystem.Spacing.md)
                }
            }
            .navigationTitle("MacParakeet")
            .mobileNavigationBarTitleDisplayModeInline()
            .alert("Recording Error", isPresented: $showingErrorAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(coordinator.errorMessage ?? "Failed to initialize microphone or speech recognizer.")
            }
            .onReceive(NotificationCenter.default.publisher(for: .macParakeetStartMobileDictation)) { _ in
                if !coordinator.isRecording {
                    mode = .dictate
                    startRecording()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .macParakeetStartMobileMeeting)) { _ in
                if !coordinator.isRecording {
                    mode = .meeting
                    startRecording()
                }
            }
        }
    }

    // MARK: - Actions

    private func startRecording() {
        Task {
            do {
                try await coordinator.startRecording(isMeeting: mode == .meeting)
                MobileDesignSystem.Haptics.heavy()
            } catch {
                showingErrorAlert = true
                MobileDesignSystem.Haptics.warningAmberColorHaptic()
            }
        }
    }

    private func togglePause() {
        MobileDesignSystem.Haptics.medium()
        coordinator.togglePause()
    }

    private func stopRecording() {
        Task {
            let transcript = await coordinator.stopRecording()
            MobileDesignSystem.Haptics.success()

            if mode == .dictate && !transcript.isEmpty {
                PlatformPasteboard.copy(transcript)
                copiedConfirmation = true
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                copiedConfirmation = false
            }
        }
    }

    private func discardRecording() {
        MobileDesignSystem.Haptics.warningAmberColorHaptic()
        coordinator.discardRecording()
    }
}

extension MobileDesignSystem.Haptics {
    public static func warningAmberColorHaptic() {
        #if canImport(UIKit) && !os(macOS)
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
        #endif
    }
}
