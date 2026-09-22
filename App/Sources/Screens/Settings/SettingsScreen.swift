import ChirpCore
import ChirpEngineFluidAudio
import ChirpFeatures
import ChirpUI
import SwiftUI

/// Tab 4 (canvas `Settings.dc.html`): Capture (M2: trigger help, stop mode, keep audio), Speech (real model management), Privacy, Text,
/// About (the build stamp) and, in DEBUG builds, Diagnostics.
struct SettingsScreen: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var placeholder: Placeholder?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Settings")
                        .chirpTitleFont(28, .heavy)
                        .foregroundStyle(Tokens.Color.ink)
                        .frame(minHeight: 44, alignment: .leading)
                        .accessibilityAddTraits(.isHeader)
                    captureGroup
                    speechGroup
                    privacyGroup
                    textGroup
                    AboutSection()
                    #if DEBUG
                    DiagnosticsSection()
                    #endif
                }
                .padding(.horizontal, 24)
                .padding(.top, 8)
                .padding(.bottom, 32)
            }
            .background(Tokens.Color.ground)
            .statusBarScrim()
            .toolbar(.hidden, for: .navigationBar)
        }
        .sheet(item: $placeholder) { NotBuiltYetSheet(placeholder: $0) }
        .alert(
            "Model action failed",
            isPresented: Binding(
                get: { environment.speechSettings.lastError != nil },
                set: { if !$0 { environment.speechSettings.dismissError() } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(environment.speechSettings.lastError ?? "")
        }
        .task {
            await environment.speechSettings.refresh()
            await environment.textRules.load()
        }
    }

    // MARK: - Capture (M2)

    private var captureGroup: some View {
        @Bindable var speech = environment.speechSettings
        return SettingsGroup(
            title: "Capture",
            footer:
                "With “Keep dictation audio” off, a dictation’s recording is deleted as soon as its text is saved, so "
                + "it cannot be played back or retried."
        ) {
            helpRow(title: "Dictation trigger", value: "Action Button", topic: .actionButton)
            helpRow(title: "Back Tap", value: "How to set up", topic: .backTap)
            SettingsRow(
                title: "Stop mode",
                caption: "Tap Stop & copy, or press the Action Button again. Stopping when you stop speaking is not "
                    + "built yet."
            ) {
                Text("Tap to stop")
                    .chirpFont(15)
                    .foregroundStyle(Tokens.Color.secondary)
            }
            SettingsRow(title: "Keep dictation audio", caption: "For playback and Retry in the Library") {
                Toggle("Keep dictation audio", isOn: $speech.settingsValue.keepDictationAudio)
                    .labelsHidden()
                    .tint(Tokens.Color.success)
            }
        }
    }

    /// Opens the steps for a trigger iOS lets only the person assign.
    private func helpRow(title: String, value: String, topic: DictationTriggerHelpScreen.Topic) -> some View {
        NavigationLink {
            DictationTriggerHelpScreen(topic: topic)
        } label: {
            SettingsRow(title: title) {
                Text(value)
                    .chirpFont(15)
                    .foregroundStyle(Tokens.Color.secondary)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Tokens.Color.mutedText)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Speech

    private var speechGroup: some View {
        @Bindable var speech = environment.speechSettings
        let running = environment.runningVariant
        let selected = speech.settingsValue.parakeetVariant
        return SettingsGroup(title: "Speech") {
            ModelAssetRow(
                title: "Speech model",
                value: Self.variantName(running),
                status: speech.speechStatus,
                approximateDownloadBytes: ParakeetEngine.descriptor(for: running).approximateDownloadBytes,
                runsOn: "Neural Engine",
                onDownload: { environment.downloadSpeechModel() },
                onDelete: { Task { await speech.deleteSpeechModel() } }
            )
            SettingsRow(
                title: "Model version",
                caption: selected == running
                    ? "v3: 25 European languages · v2: English only"
                    : "Takes effect next time you open Parakeet",
                captionColor: selected == running ? Tokens.Color.secondary : AppColor.accentText
            ) {
                Picker("Model version", selection: $speech.settingsValue.parakeetVariant) {
                    Text("v3").tag(ParakeetVariant.v3)
                    Text("v2").tag(ParakeetVariant.v2)
                }
                .pickerStyle(.segmented)
                .frame(width: 120)
                .labelsHidden()
            }
            SettingsRow(title: "Language") {
                Text(running == .v3 ? "Automatic (25 languages)" : "English")
                    .chirpFont(15)
                    .foregroundStyle(Tokens.Color.secondary)
            }
            .accessibilityElement(children: .combine)
            SettingsRow(
                title: "Speaker labels",
                caption: speakerLabelsCaption
            ) {
                Toggle("Speaker labels", isOn: $speech.settingsValue.speakerLabelsEnabled)
                    .labelsHidden()
                    .tint(Tokens.Color.success)
            }
            if speech.isDiarizerAvailable {
                ModelAssetRow(
                    title: "Speaker model",
                    value: "Community-1",
                    status: speech.diarizerStatus,
                    approximateDownloadBytes: FluidAudioDiarizer.engineDescriptor.approximateDownloadBytes,
                    runsOn: "Neural Engine",
                    onDownload: { environment.downloadDiarizer() },
                    onDelete: { Task { await speech.deleteDiarizer() } }
                )
            }
        }
    }

    private var speakerLabelsCaption: String? {
        let speech = environment.speechSettings
        guard speech.settingsValue.speakerLabelsEnabled else { return "Off — transcripts won’t say who spoke" }
        if case .ready = speech.diarizerStatus { return "Labels who spoke when" }
        return "Download the speaker model below to label who spoke"
    }

    static func variantName(_ variant: ParakeetVariant) -> String {
        variant == .v3 ? "Parakeet v3" : "Parakeet v2"
    }

    // MARK: - Privacy

    private var privacyGroup: some View {
        SettingsGroup(title: "Privacy") {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: Tokens.Radius.iconTile, style: .continuous)
                        .fill(Tokens.Color.privacyBadgeFill)
                    Image(systemName: "lock.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Tokens.Color.privacyBadgeInk)
                }
                .frame(width: 34, height: 34)
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Everything stays on this iPhone")
                        .chirpFont(15.5)
                        .foregroundStyle(Tokens.Color.ink)
                    Text("Audio, transcripts, notes — no account, no upload")
                        .chirpFont(12.5)
                        .foregroundStyle(Tokens.Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(minHeight: 64)
            .accessibilityElement(children: .combine)

            Button {
                placeholder = .cloudModels
            } label: {
                SettingsRow(
                    title: "Cloud models for Ask", caption: "Off — Ask and Transforms run locally · Milestone M4"
                ) {
                    Toggle("Cloud models for Ask", isOn: .constant(false))
                        .labelsHidden()
                        .disabled(true)
                        .allowsHitTesting(false)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityValue("Off")
            .accessibilityHint("Not built yet, milestone M4")
        }
    }

    // MARK: - Text

    private var textGroup: some View {
        @Bindable var speech = environment.speechSettings
        return SettingsGroup(
            title: "Text",
            footer:
                "Raw keeps Parakeet’s text exactly as recognized. Clean removes fillers like “um”, tidies spacing "
                + "and applies your custom words and snippets. Applies to the next transcription; a dictation with "
                + "“Polish after” is always cleaned."
        ) {
            SettingsRow(title: "Clean-up") {
                Picker("Clean-up", selection: $speech.settingsValue.cleanupMode) {
                    Text("Raw").tag(CleanupMode.raw)
                    Text("Clean").tag(CleanupMode.clean)
                }
                .pickerStyle(.segmented)
                .frame(width: 140)
                .labelsHidden()
            }
            NavigationLink {
                TextRulesScreen(model: environment.textRules)
            } label: {
                SettingsRow(title: "Custom words & snippets") {
                    Text(environment.textRules.count == 0 ? "None" : "\(environment.textRules.count)")
                        .chirpFont(15)
                        .monospacedDigit()
                        .foregroundStyle(Tokens.Color.secondary)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Tokens.Color.mutedText)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}
