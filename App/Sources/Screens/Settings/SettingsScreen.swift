import ChirpCore
import ChirpEngineFluidAudio
import ChirpFeatures
import ChirpUI
import SwiftUI

/// Tab 4 (canvas `Settings.dc.html`): Capture (M2 placeholders), Speech (real model management), Privacy, Text,
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
        .task { await environment.speechSettings.refresh() }
    }

    // MARK: - Capture (M2)

    private var captureGroup: some View {
        SettingsGroup(title: "Capture") {
            PlaceholderRow(
                title: "Dictation trigger", value: "Action Button", placeholder: .dictationTrigger,
                open: { placeholder = $0 })
            PlaceholderRow(title: "Back Tap", value: "Double tap", placeholder: .backTap, open: { placeholder = $0 })
            PlaceholderRow(title: "Stop mode", value: "Tap to stop", placeholder: .stopMode, open: { placeholder = $0 })
        }
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
                onDownload: { Task { await speech.downloadSpeechModel() } },
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
                    onDownload: { Task { await speech.downloadDiarizer() } },
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
                "Raw keeps Parakeet’s text exactly as recognized. Clean removes fillers like “um” and tidies "
                + "spacing, and will apply your custom words once they arrive in M2. Applies to the next transcription."
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
            PlaceholderRow(
                title: "Custom words & snippets", value: "None", placeholder: .customWords, open: { placeholder = $0 })
        }
    }
}
