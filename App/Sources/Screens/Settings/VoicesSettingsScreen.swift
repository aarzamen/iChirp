import ChirpCore
import ChirpFeatures
import ChirpUI
import SwiftUI

/// The Settings group that opens Settings → Voices (plan 020), showing the voice Listen uses now.
struct VoiceSettingsGroup: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        SettingsGroup(title: "Read aloud") {
            NavigationLink {
                VoicesSettingsScreen()
            } label: {
                SettingsRow(title: "Voices", caption: environment.voiceSettings.summary) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Tokens.Color.mutedText)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityHint("Choose the voice that reads documents, transcripts and answers aloud")
        }
    }
}

/// Settings → Voices: Mac companion or Grok voices; the companion's voices and style; Grok's stock voices, a
/// free-text Voice ID and the xAI key (Keychain only); Test voice. No Apple voices (owner's choice).
struct VoicesSettingsScreen: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        let model = environment.voiceSettings
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Voices")
                    .chirpTitleFont(28, .heavy)
                    .foregroundStyle(Tokens.Color.ink)
                    .frame(minHeight: 44, alignment: .leading)
                    .accessibilityAddTraits(.isHeader)
                Text("Listen reads documents, transcripts and Ask answers aloud in the voice you pick here.")
                    .chirpFont(14)
                    .foregroundStyle(Tokens.Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)

                providerGroup(model)
                companionGroup(model)
                grokGroup(model)
                testGroup(model)
            }
            .padding(.horizontal, 24)
            .padding(.top, 8)
            .padding(.bottom, 32)
        }
        .background(Tokens.Color.ground)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .task { await model.refresh() }
        .voiceConfirmation(for: environment.voicePlayer)
        .alert(
            "Couldn’t change the key",
            isPresented: Binding(get: { model.lastError != nil }, set: { if !$0 { model.dismissError() } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.lastError ?? "")
        }
    }

    // MARK: - Provider

    private func providerGroup(_ model: VoiceSettingsViewModel) -> some View {
        SettingsGroup(
            title: "Read aloud with",
            footer:
                "Clinical text is read only by a Mac you trust. Grok voices ask you before each clinical reading, and "
                + "nothing is remembered."
        ) {
            ForEach(VoiceProviderKind.allCases) { kind in
                Button {
                    model.choose(kind)
                } label: {
                    SettingsRow(title: kind.displayName, caption: providerCaption(kind)) {
                        if model.settings.provider == kind {
                            Image(systemName: "checkmark")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(AppColor.accentText)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(model.settings.provider == kind ? .isSelected : [])
            }
        }
    }

    private func providerCaption(_ kind: VoiceProviderKind) -> String {
        switch kind {
        case .companion: "Your voices on your Mac · home network"
        case .xai: "xAI · internet · asks for clinical"
        }
    }

    // MARK: - Mac companion

    private func companionGroup(_ model: VoiceSettingsViewModel) -> some View {
        @Bindable var model = model
        return SettingsGroup(
            title: "Mac companion",
            footer:
                "Runs ChoiceVoice's Qwen3-TTS and Kokoro on your Mac. Set its address and pairing token in Settings → "
                + "Mac companion; the text goes only to that Mac."
        ) {
            SettingsRow(title: "Status", caption: companionCaption(model.companionState)) {
                Button {
                    Task { await model.recheckCompanion() }
                } label: {
                    CapsuleButtonLabel(title: "Check again", kind: .tinted)
                }
                .buttonStyle(.plain)
                .disabled(model.companionState == .checking)
            }
            ForEach(model.companionVoices) { voice in
                Button {
                    model.chooseCompanionVoice(voice.id)
                } label: {
                    SettingsRow(title: voice.name, caption: voice.detail) {
                        if model.settings.companionVoiceID == voice.id {
                            Image(systemName: "checkmark")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(AppColor.accentText)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(model.settings.companionVoiceID == voice.id ? .isSelected : [])
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Style")
                    .chirpFont(15.5)
                    .foregroundStyle(Tokens.Color.ink)
                TextField("Optional, e.g. calm and unhurried", text: $model.settings.companionStyle)
                    .chirpFont(15)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityLabel("Style")
                Text("A delivery instruction for voices that take one (Qwen3-TTS).")
                    .chirpFont(12.5)
                    .foregroundStyle(Tokens.Color.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
    }

    private func companionCaption(_ state: VoiceSettingsViewModel.CompanionState) -> String {
        switch state {
        case .checking: "Checking…"
        case .ready: "Ready"
        case .unavailable(let sentence): sentence
        }
    }

    // MARK: - Grok voices

    private func grokGroup(_ model: VoiceSettingsViewModel) -> some View {
        @Bindable var model = model
        let hasCustom = !model.settings.xaiCustomVoiceID.trimmingCharacters(in: .whitespaces).isEmpty
        return SettingsGroup(
            title: "Grok voices",
            footer:
                "The key is kept in this iPhone's Keychain, never in settings or logs. A Voice ID (for example a voice "
                + "you cloned in your xAI account) stays on this iPhone."
        ) {
            ForEach(model.stockXAIVoices) { voice in
                Button {
                    model.chooseStockXAIVoice(voice.id)
                } label: {
                    SettingsRow(title: voice.name) {
                        if !hasCustom, model.settings.xaiStockVoiceID == voice.id {
                            Image(systemName: "checkmark")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(AppColor.accentText)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(!hasCustom && model.settings.xaiStockVoiceID == voice.id ? .isSelected : [])
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Voice ID")
                    .chirpFont(15.5)
                    .foregroundStyle(Tokens.Color.ink)
                TextField("Optional: a voice ID from your xAI account", text: $model.settings.xaiCustomVoiceID)
                    .chirpFont(15)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityLabel("Voice ID")
                Text(hasCustom ? "Used instead of the voice above." : "Leave empty to use the voice above.")
                    .chirpFont(12.5)
                    .foregroundStyle(Tokens.Color.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            keyRow(model)
        }
    }

    private func keyRow(_ model: VoiceSettingsViewModel) -> some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("xAI API key")
                    .chirpFont(15.5)
                    .foregroundStyle(Tokens.Color.ink)
                Spacer(minLength: 8)
                Text(keyCaption(model.keyState))
                    .chirpFont(12.5)
                    .foregroundStyle(isKeyProblem(model.keyState) ? AppColor.error : Tokens.Color.secondary)
                    .multilineTextAlignment(.trailing)
            }
            SecureField(
                model.keyState == .missing ? "Paste your key" : "Paste a new key to replace it", text: $model.keyDraft
            )
            .chirpFont(15)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .accessibilityLabel("xAI API key")
            HStack(spacing: 10) {
                Button {
                    model.saveKey()
                } label: {
                    CapsuleButtonLabel(title: "Save key", kind: .filled)
                }
                .buttonStyle(.plain)
                .disabled(model.keyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                if model.keyState != .missing {
                    Button {
                        Task { await model.checkKey() }
                    } label: {
                        CapsuleButtonLabel(title: "Check key", kind: .tinted)
                    }
                    .buttonStyle(.plain)
                    .disabled(model.keyState == .checking)
                    Button {
                        model.removeKey()
                    } label: {
                        CapsuleButtonLabel(title: "Remove", kind: .destructive)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private func keyCaption(_ state: VoiceSettingsViewModel.KeyState) -> String {
        switch state {
        case .missing: "No key yet"
        case .saved: "Saved in the Keychain"
        case .checking: "Checking…"
        case .valid: "Key works"
        case .invalid(let sentence): sentence
        }
    }

    private func isKeyProblem(_ state: VoiceSettingsViewModel.KeyState) -> Bool {
        switch state {
        case .missing, .invalid: true
        default: false
        }
    }

    // MARK: - Test

    private func testGroup(_ model: VoiceSettingsViewModel) -> some View {
        let player = environment.voicePlayer
        let testing = player.isReading(.voiceTest)
        return SettingsGroup(
            title: "Try it",
            footer: "Test voice reads one fixed sentence: “\(VoiceSettingsViewModel.testSentence)”"
        ) {
            SettingsRow(
                title: "Test voice",
                caption: testing ? VoiceStatus.text(player.state) : model.setupProblem,
                captionColor: testing && !VoiceStatus.isFailure(player.state)
                    ? Tokens.Color.secondary : AppColor.error
            ) {
                Button {
                    if testing, !VoiceStatus.isFailure(player.state) {
                        player.stop()
                    } else {
                        Task { await model.testVoice() }
                    }
                } label: {
                    CapsuleButtonLabel(
                        title: testing && !VoiceStatus.isFailure(player.state) ? "Stop" : "Test voice", kind: .filled)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(testing && !VoiceStatus.isFailure(player.state) ? "Stop test" : "Test voice")
            }
        }
    }
}
