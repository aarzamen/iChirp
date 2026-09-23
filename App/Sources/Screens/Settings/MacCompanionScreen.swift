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
        Form {
            Section {
                Text(
                    "The Parakeet companion runs on your Mac. It speaks with your own voices and fetches the audio of "
                        + "YouTube videos that have no captions. Start it on the Mac with scripts/companion.sh, then "
                        + "enter what it prints."
                )
                .chirpFont(14)
                .foregroundStyle(Tokens.Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                TextField("my-mac.local or 192.168.1.20", text: $model.host)
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focused, equals: .host)
                    .accessibilityLabel("Host")
                TextField("Port (8765)", text: $model.port)
                    .keyboardType(.numberPad)
                    .focused($focused, equals: .port)
                    .accessibilityLabel("Port")
                SecureField(
                    model.hasSavedToken ? "Pairing token saved · type to replace" : "Pairing token",
                    text: $model.newToken
                )
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focused, equals: .token)
                .accessibilityLabel("Pairing token")
            } header: {
                Text("Your Mac")
            } footer: {
                Text(
                    "The pairing token is kept in this iPhone’s Keychain, only on this device, never synced or logged. "
                        + "This iPhone and the Mac must be on the same Wi-Fi.")
            }

            Section {
                Toggle("Trusted for clinical text", isOn: $model.isTrusted)
                    .tint(Tokens.Color.success)
                    .disabled(model.isInternetAddress)
            } header: {
                Text("Clinical text")
            } footer: {
                Text(trustFooter)
            }

            Section {
                Button("Save") {
                    focused = nil
                    model.save()
                }
                .bold()
                .disabled(!model.hasUnsavedChanges)
                Button {
                    focused = nil
                    model.testConnection()
                } label: {
                    HStack {
                        Text("Test connection")
                        Spacer()
                        testBadge
                    }
                }
                .disabled(model.testState == .testing)
            } footer: {
                testFooter
            }

            if model.isConfigured {
                Section {
                    Button("Remove Mac companion", role: .destructive) { confirmingRemove = true }
                } footer: {
                    Text("Forgets this Mac and deletes its pairing token from this iPhone. Your transcripts stay.")
                }
            }
        }
        .scrollContentBackground(.hidden)
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

    private var trustFooter: String {
        if model.isInternetAddress {
            return "This address is on the internet, so it can’t be trusted with clinical text."
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
            Label("Connected", systemImage: "checkmark.circle.fill")
                .foregroundStyle(Tokens.Color.success)
        case .failed:
            Label("Failed", systemImage: "xmark.circle.fill")
                .foregroundStyle(AppColor.error)
        }
    }

    @ViewBuilder private var testFooter: some View {
        switch model.testState {
        case .succeeded(let summary, let details):
            VStack(alignment: .leading, spacing: 2) {
                Text(summary).foregroundStyle(Tokens.Color.ink)
                ForEach(details, id: \.self) { Text($0) }
            }
        case .failed(let message):
            Text(message).foregroundStyle(AppColor.error)
        case .idle, .testing:
            Text("Asks the Mac what it offers and checks the pairing token. Sends no text and no links.")
        }
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
