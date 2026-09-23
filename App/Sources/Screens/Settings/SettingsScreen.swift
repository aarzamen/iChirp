import ChirpCore
import ChirpEngineFluidAudio
import ChirpFeatures
import ChirpUI
import SwiftUI

/// Tab 4 (canvas `Settings.dc.html`): Capture (M2: trigger help, stop mode, keep audio), Speech (real model management),
/// Privacy (with Settings → Models, M4), Text, About (the build stamp) and, in DEBUG builds, Diagnostics.
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
                    MeetingSettingsGroup()  // M3
                    speechGroup
                    privacyGroup
                    StructureModelsSettingsGroup()  // M6: Needle 3, the STUB, the gate, voice commands, Eval
                    textGroup
                    VoiceSettingsGroup()  // plan 020: Settings → Voices
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
            // F78: "How to set up", like Back Tap below — the value is a help link, not the trigger's name, and
            // reading "Action Button" here looked like already-configured state.
            helpRow(title: "Dictation trigger", value: "How to set up", topic: .actionButton)
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
        // F76: "Speech engines" is the one entry point for Parakeet's status, size and Download/Delete now — its
        // own "Engines" list already shows Parakeet correctly (it used to disagree here: a static "500 MB"
        // estimate beside the Engines screen's real "On device · 483 MB"). Model version moved there too.
        return SettingsGroup(title: "Speech") {
            SpeechEnginesSettingsLink()  // M7: live and final engines, Apple Speech, WhisperKit, benchmark, version
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

    // MARK: - Privacy

    private var privacyGroup: some View {
        let reach = contentReach
        let onDevice = reach.level == .onDevice
        return SettingsGroup(title: "Privacy") {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: Tokens.Radius.iconTile, style: .continuous)
                        .fill(Tokens.Color.privacyBadgeFill)
                    Image(systemName: onDevice ? "lock.fill" : "network")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Tokens.Color.privacyBadgeInk)
                }
                .frame(width: 34, height: 34)
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    // F74: this claim is only true while `ContentReach` — the same computation Capture's header
                    // chip uses, so the two screens never disagree — says every route is on-device.
                    Text(onDevice ? "Everything stays on this iPhone" : "Some settings can leave this iPhone")
                        .chirpFont(15.5)
                        .foregroundStyle(Tokens.Color.ink)
                    Text(onDevice ? "Audio, transcripts, notes — no account, no upload" : reach.summary)
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

            // M4: Settings → Models (on-device, home-network and cloud models; keys in the Keychain).
            ModelsSettingsLink()
            // Plan 019: Settings → Mac companion (host, port, pairing token in the Keychain, trusted).
            MacCompanionSettingsLink()
        }
    }

    /// Where the configured routes send content now (UX audit F13/F74) — the same `ContentReach` computation
    /// Capture's header chip and "Where things run" sheet use.
    private var contentReach: ContentReach {
        ContentReach.current(
            speechEngineName: environment.finalSpeechModel.name,
            defaultModel: environment.languageModels.defaultChoice,
            otherProviders: environment.languageModels.choices,
            voice: environment.voiceSettings.settings.provider,
            companionTrusted: environment.companionConfiguration.companionEndpoint()?.isTrusted ?? false,
            jevEnabled: environment.jevSettingsModel.isEnabled)
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
                // F77: no fixed width — a hard-coded pixel width squeezed this at accessibility Dynamic Type
                // sizes; let it size to its own content instead.
                .fixedSize()
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
