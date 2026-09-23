import ChirpCore
import ChirpFeatures
import ChirpUI
import SwiftUI

/// The Settings row that opens Settings → Mac companion (plan 019), showing whether one is set up.
struct MacCompanionSettingsLink: View {
    @Environment(AppEnvironment.self) private var environment
    /// Re-read on every appearance (the store is not observable), so the row is current after editing.
    @State private var endpoint: CompanionEndpoint?

    var body: some View {
        NavigationLink {
            MacCompanionScreen(store: environment.companionSettings)
        } label: {
            SettingsRow(title: "Mac companion", caption: caption(endpoint)) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Tokens.Color.mutedText)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .onAppear { endpoint = environment.companionSettings.companionEndpoint() }
    }

    private func caption(_ endpoint: CompanionEndpoint?) -> String {
        guard let endpoint else { return "Your voices and YouTube audio from your Mac · not set up" }
        return endpoint.normalizedHost + (endpoint.isTrusted ? " · trusted for clinical text" : "")
    }
}

/// Settings → Mac companion: the host, port and pairing token the companion printed on the Mac, the trusted switch,
/// Test connection and Remove. The token goes to the Keychain and is never shown again.
struct MacCompanionScreen: View {
    @State private var model: CompanionSettingsViewModel
    @State private var confirmingRemove = false
    @FocusState private var focused: Field?

    private enum Field {
        case host, port, token
    }

    init(store: CompanionSettingsStore) {
        _model = State(initialValue: CompanionSettingsViewModel(store: store))
    }

    var body: some View {
        @Bindable var model = model
        // F85: restyled with the app's own `SettingsGroup`/`SettingsRow` instead of a system `Form` (the only
        // screen in Settings that still looked like one), and Test connection now comes before Save.
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Mac companion")
                    .chirpTitleFont(28, .heavy)
                    .foregroundStyle(Tokens.Color.ink)
                    .frame(minHeight: 44, alignment: .leading)
                    .accessibilityAddTraits(.isHeader)
                Text(
                    "The Parakeet companion runs on your Mac. It speaks with your own voices and fetches the audio "
                        + "of YouTube videos that have no captions. Start Parakeet companion on your Mac, then "
                        + "enter the address and pairing code it shows."
                )
                .chirpFont(14)
                .foregroundStyle(Tokens.Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)

                SettingsGroup(
                    title: "Your Mac",
                    footer:
                        "The pairing token is kept in this iPhone’s Keychain, only on this device, never synced or "
                        + "logged. This iPhone and the Mac must be on the same Wi-Fi."
                ) {
                    labeledField(
                        "Host", placeholder: "my-mac.local or 192.168.1.20", text: $model.host, field: .host,
                        keyboard: .URL, contentType: .URL)
                    labeledField("Port", placeholder: "8765", text: $model.port, field: .port, keyboard: .numberPad)
                    labeledSecureField(
                        "Pairing token",
                        placeholder: model.hasSavedToken ? "Saved · type to replace" : "From the Mac",
                        text: $model.newToken, field: .token)
                }

                SettingsGroup(title: "Clinical text", footer: trustFooter) {
                    SettingsRow(title: "Trusted for clinical text") {
                        Toggle("Trusted for clinical text", isOn: $model.isTrusted)
                            .labelsHidden()
                            .tint(Tokens.Color.success)
                            .disabled(model.isInternetAddress)
                    }
                }

                SettingsGroup(title: "Connect", footer: testFooterText, footerColor: testFooterColor) {
                    Button {
                        focused = nil
                        model.testConnection()
                    } label: {
                        SettingsRow(title: "Test connection") { testBadge }
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(model.testState == .testing)
                    Button {
                        focused = nil
                        model.save()
                    } label: {
                        SettingsRow(title: "Save") { EmptyView() }
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!model.hasUnsavedChanges)
                    .opacity(model.hasUnsavedChanges ? 1 : 0.5)
                }

                if model.isConfigured {
                    SettingsGroup(
                        title: "Remove",
                        footer: "Forgets this Mac and deletes its pairing token from this iPhone. Your transcripts "
                            + "stay."
                    ) {
                        Button {
                            confirmingRemove = true
                        } label: {
                            SettingsRow(title: "Remove Mac companion", titleColor: AppColor.error) {
                                EmptyView()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 8)
            .padding(.bottom, 32)
        }
        .background(Tokens.Color.ground)
        .navigationTitle("Mac companion")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .tint(AppColor.accentText)
        .onAppear {
            #if DEBUG
            MacCompanionPreviewLaunch.apply(to: model)
            #endif
        }
        .confirmationDialog(
            "Remove the Mac companion?", isPresented: $confirmingRemove, titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) { model.remove() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Parakeet forgets this Mac and its pairing token.")
        }
        .alert(
            "Couldn’t save",
            isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.dismissError() } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    /// A visible label above a plain text field (F85: the old `Form` relied on placeholder text alone).
    private func labeledField(
        _ title: String, placeholder: String, text: Binding<String>, field: Field,
        keyboard: UIKeyboardType, contentType: UITextContentType? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .chirpFont(15.5)
                .foregroundStyle(Tokens.Color.ink)
            TextField(placeholder, text: text)
                .chirpFont(15)
                .keyboardType(keyboard)
                .textContentType(contentType)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focused, equals: field)
                .accessibilityLabel(title)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    /// The pairing-token counterpart of `labeledField`, with a `SecureField`.
    private func labeledSecureField(
        _ title: String, placeholder: String, text: Binding<String>, field: Field
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .chirpFont(15.5)
                .foregroundStyle(Tokens.Color.ink)
            SecureField(placeholder, text: text)
                .chirpFont(15)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focused, equals: field)
                .accessibilityLabel(title)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var testFooterText: String {
        switch model.testState {
        case .succeeded(let summary, let details):
            return ([summary] + details).joined(separator: "\n")
        case .failed(let message):
            return message
        case .idle, .testing:
            return "Asks the Mac what it offers and checks the pairing token. Sends no text and no links."
        }
    }

    private var trustFooter: String {
        if model.isInternetAddress {
            return "This address is on the internet. The companion speaks plain http, so it must be on your home "
                + "network: use your Mac’s name (like my-mac.local) or its home IP address."
        }
        return model.isTrusted
            ? "Clinical text may be spoken by this Mac’s voices without asking each time. Only for your own Mac on "
                + "your home network."
            : "Off: clinical text is never sent to this Mac unless you allow it for that one time."
    }

    @ViewBuilder private var testBadge: some View {
        switch model.testState {
        case .idle: EmptyView()
        case .testing: ProgressView()
        case .succeeded:
            // F80: successInk, not success — success measures 3.06:1 as text, below 4.5:1.
            Label("Connected", systemImage: "checkmark.circle.fill")
                .foregroundStyle(Tokens.Color.successInk)
        case .failed:
            Label("Failed", systemImage: "xmark.circle.fill")
                .foregroundStyle(AppColor.error)
        }
    }

    private var testFooterColor: Color {
        if case .failed = model.testState { return AppColor.error }
        return Tokens.Color.secondary
    }
}

#if DEBUG
/// UI-tour and QA launch arguments: `-MacCompanionHost <host>` and `-MacCompanionPort <port>` prefill the form (never
/// a token: that is typed or pasted by the person).
enum MacCompanionPreviewLaunch {
    @MainActor static func apply(to model: CompanionSettingsViewModel) {
        guard !model.isConfigured, model.host.isEmpty else { return }
        let arguments = ProcessInfo.processInfo.arguments
        func value(after flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
            return arguments[index + 1]
        }
        if let host = value(after: "-MacCompanionHost") { model.host = host }
        if let port = value(after: "-MacCompanionPort") { model.port = port }
    }
}
#endif
