import ChirpCore
import ChirpFeatures
import ChirpUI
import SwiftUI

/// The Settings → Privacy row that opens Settings → Models, showing the model Transform and Ask use now.
struct ModelsSettingsLink: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        let choice = environment.languageModels.defaultChoice
        NavigationLink {
            ModelsSettingsScreen()
        } label: {
            SettingsRow(title: "Models for Ask and Transforms", caption: "\(choice.name) · \(choice.place)") {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Tokens.Color.mutedText)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }
}

/// Settings → Models: which model Transform and Ask use, Apple's on-device model and its availability, and the
/// providers the owner added (their API keys live only in the Keychain).
struct ModelsSettingsScreen: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var editing: LanguageModelProviderDraft?
    @State private var error: String?

    var body: some View {
        let models = environment.languageModels
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Models")
                    .chirpTitleFont(28, .heavy)
                    .foregroundStyle(Tokens.Color.ink)
                    .frame(minHeight: 44, alignment: .leading)
                    .accessibilityAddTraits(.isHeader)
                Text("Transform and Ask use the model you pick here. You can pick another for a single run.")
                    .chirpFont(14)
                    .foregroundStyle(Tokens.Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)

                SettingsGroup(
                    title: "Use for Transform and Ask",
                    footer:
                        "Clinical transcripts only go to this iPhone or a Mac you trust. Anything else asks you "
                        + "before each run, and nothing is remembered."
                ) {
                    ForEach(models.choices) { choice in
                        Button {
                            setDefault(choice)
                        } label: {
                            SettingsRow(title: choice.name, caption: choiceCaption(choice)) {
                                if choice == models.defaultChoice {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 15, weight: .bold))
                                        .foregroundStyle(AppColor.accentText)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityElement(children: .combine)
                        .accessibilityAddTraits(choice == models.defaultChoice ? .isSelected : [])
                    }
                }

                SettingsGroup(title: "On this iPhone") {
                    SettingsRow(title: "Apple on-device model", caption: onDeviceCaption(models.onDeviceAvailability)) {
                        onDeviceBadge(models.onDeviceAvailability)
                    }
                    .accessibilityElement(children: .combine)
                }

                // M7 (ADR-015): Qwen models through llama.cpp, downloaded on request.
                OnDeviceModelsSection()

                SettingsGroup(
                    title: "Your models",
                    footer:
                        "API keys are kept in this iPhone's Keychain, never in settings files or logs. A Mac on your "
                        + "network (Ollama or LM Studio) is reached over plain http; internet providers need https."
                ) {
                    ForEach(models.providers) { provider in
                        Button {
                            editing = models.draft(editing: provider)
                        } label: {
                            SettingsRow(title: provider.displayName, caption: providerCaption(provider)) {
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(Tokens.Color.mutedText)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityElement(children: .combine)
                        .accessibilityHint("Edit, test or delete")
                    }
                    Menu {
                        ForEach(HTTPProviderKinds.all, id: \.self) { kind in
                            Button(HTTPProviderKinds.menuTitle(kind)) {
                                editing = LanguageModelProviderDraft(kind: kind)
                            }
                        }
                    } label: {
                        SettingsRow(title: "Add a model") {
                            Image(systemName: "plus.circle.fill")
                                .font(.system(size: 20))
                                .foregroundStyle(AppColor.accentText)
                        }
                        .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Add a model")
                }

                // M6a (plan 021): Jev, the opt-in cloud decision model.
                DecisionModelsSection()
            }
            .padding(.horizontal, 24)
            .padding(.top, 8)
            .padding(.bottom, 32)
        }
        .background(Tokens.Color.ground)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .task {
            await models.refresh()
            environment.jevSettingsModel.refresh()
        }
        .sheet(item: $editing) { draft in
            ProviderEditorSheet(draft: draft)
        }
        .alert(
            "Couldn’t change the model",
            isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(error ?? "")
        }
    }

    private func setDefault(_ choice: LanguageModelChoice) {
        do {
            try environment.languageModels.setDefault(choice)
        } catch {
            self.error = Formatting.message(for: error)
        }
    }

    private func choiceCaption(_ choice: LanguageModelChoice) -> String {
        switch choice.locality {
        case .onDevice: return "On this iPhone"
        case .localNetwork:
            return choice.isTrustedForClinical
                ? "Home network · trusted for clinical" : "Home network · asks for clinical"
        case .cloud: return "Internet · asks for clinical"
        }
    }

    private func providerCaption(_ provider: LanguageModelProviderConfiguration) -> String {
        var parts = [provider.kind.displayName]
        if !provider.modelName.isEmpty { parts.append(provider.modelName) }
        switch provider.locality {
        case .localNetwork:
            parts.append(provider.isTrustedLocalNetworkHost ? "home network, trusted" : "home network")
        case .cloud: parts.append("internet")
        case .onDevice: break
        }
        return parts.joined(separator: " · ")
    }

    private func onDeviceCaption(_ availability: LanguageModelAvailability?) -> String {
        switch availability {
        case nil: "Checking…"
        case .available?: "Ready. Runs on this iPhone; nothing leaves it."
        case .unavailable(let reason)?: reason.message
        }
    }

    @ViewBuilder private func onDeviceBadge(_ availability: LanguageModelAvailability?) -> some View {
        if availability == .available {
            Text("Ready")
                .chirpFont(12, .bold)
                .foregroundStyle(Tokens.Color.privacyBadgeInk)
                .padding(.horizontal, 9)
                .frame(minHeight: 24)
                .background(Capsule().fill(Tokens.Color.privacyBadgeFill))
        } else if availability != nil {
            Text("Unavailable")
                .chirpFont(12, .bold)
                .foregroundStyle(Tokens.Color.secondary)
                .padding(.horizontal, 9)
                .frame(minHeight: 24)
                .background(Capsule().fill(AppColor.quietFill))
        }
    }
}

/// The HTTP provider kinds the Add menu offers, in plain words.
enum HTTPProviderKinds {
    static let all: [LanguageModelProviderKind] = [.ollama, .openAICompatible, .anthropic]

    static func menuTitle(_ kind: LanguageModelProviderKind) -> String {
        switch kind {
        case .ollama: "Ollama on your Mac"
        case .openAICompatible: "LM Studio, OpenAI or compatible"
        case .anthropic: "Anthropic (Claude)"
        case .appleFoundationModels: kind.displayName
        }
    }
}
