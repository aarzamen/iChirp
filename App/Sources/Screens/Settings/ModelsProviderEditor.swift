import ChirpCore
import ChirpFeatures
import ChirpUI
import SwiftUI

/// Add or edit one provider: type, address (where it runs is derived from it), name, model (typed or picked from the
/// server), API key (to the Keychain; a blank field keeps the stored key), the trusted switch for a Mac on the home
/// network only, the context window, Test connection, and Delete.
struct ProviderEditorSheet: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    @State private var draft: LanguageModelProviderDraft
    @State private var check: LanguageModelsViewModel.ConnectionCheck = .idle
    @State private var serverModels: [String] = []
    @State private var modelsMessage: String?
    @State private var isLoadingModels = false
    @State private var confirmingDelete = false
    @State private var error: String?

    init(draft: LanguageModelProviderDraft) {
        _draft = State(initialValue: draft)
    }

    var body: some View {
        NavigationStack {
            Form {
                typeSection
                addressSection
                modelSection
                keySection
                if draft.showsTrustToggle {
                    trustSection
                }
                advancedSection
                testSection
                if !draft.isNew {
                    Section {
                        Button("Delete Model", role: .destructive) { confirmingDelete = true }
                    } footer: {
                        Text("Removes this model and its key from this iPhone. Documents made with it stay.")
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Tokens.Color.ground)
            .navigationTitle(draft.isNew ? "Add Model" : "Edit Model")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") { save() }
                        .bold()
                        .disabled(draft.problem != nil)
                }
            }
            .onChange(of: draft) { _, _ in check = .idle }
            .confirmationDialog(
                "Delete \(draft.configuration.displayName)?", isPresented: $confirmingDelete, titleVisibility: .visible
            ) {
                Button("Delete Model", role: .destructive) { delete() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Its API key is removed from the Keychain too.")
            }
            .alert(
                "Couldn’t save",
                isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(error ?? "")
            }
        }
        .tint(AppColor.accentText)
    }

    // MARK: - Sections

    private var typeSection: some View {
        Section("Type") {
            Picker("Type", selection: Binding(get: { draft.kind }, set: { draft.setKind($0) })) {
                ForEach(HTTPProviderKinds.all, id: \.self) { kind in
                    Text(HTTPProviderKinds.menuTitle(kind)).tag(kind)
                }
            }
            .pickerStyle(.menu)
        }
    }

    private var addressSection: some View {
        Section {
            TextField("Address", text: $draft.baseURLText)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityLabel("Server address")
            TextField("Name (\(draft.configuration.displayName))", text: $draft.displayName)
                .accessibilityLabel("Name")
        } header: {
            Text("Server")
        } footer: {
            Text(whereItRuns)
        }
    }

    private var modelSection: some View {
        Section {
            TextField("Model name", text: $draft.modelName)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if !serverModels.isEmpty {
                Picker("On the server", selection: $draft.modelName) {
                    if !serverModels.contains(draft.modelName) {
                        Text(draft.modelName.isEmpty ? "Choose…" : draft.modelName).tag(draft.modelName)
                    }
                    ForEach(serverModels, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.menu)
            }
            Button {
                Task { await loadModels() }
            } label: {
                HStack {
                    Text(serverModels.isEmpty ? "Get models from the server" : "Refresh models")
                    if isLoadingModels {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(isLoadingModels || draft.configuration.baseURL == nil)
        } header: {
            Text("Model")
        } footer: {
            if let modelsMessage {
                Text(modelsMessage)
            } else {
                Text(modelHint)
            }
        }
    }

    private var keySection: some View {
        Section {
            SecureField(
                draft.hadStoredKey ? "Stored in the Keychain · type to replace" : "API key", text: $draft.apiKeyText
            )
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .accessibilityLabel("API key")
            if draft.hadStoredKey {
                Toggle("Remove the stored key", isOn: $draft.removesStoredKey)
                    .disabled(!draft.apiKeyText.isEmpty)
            }
        } header: {
            Text("API key")
        } footer: {
            Text(
                draft.needsAPIKey
                    ? "Required. Kept in this iPhone's Keychain, only on this device, never synced or logged."
                    : "Optional for a server on your network. Kept in this iPhone's Keychain if you add one.")
        }
    }

    private var trustSection: some View {
        Section {
            Toggle("Trust for clinical transcripts", isOn: $draft.trustsLocalNetworkHost)
                .tint(Tokens.Color.success)
        } header: {
            Text("Clinical transcripts")
        } footer: {
            Text(
                draft.trustsLocalNetworkHost
                    ? "Clinical transcripts go to \(draft.configuration.host ?? "this computer") without asking each "
                        + "time. Only for a computer you control on your home network."
                    : "Off: Parakeet asks before each run that would send a clinical transcript here.")
        }
    }

    private var advancedSection: some View {
        Section {
            TextField("Context window (tokens)", text: $draft.contextWindowText)
                .keyboardType(.numberPad)
        } header: {
            Text("Advanced")
        } footer: {
            Text(
                "Leave blank for the default: Ollama 8192, LM Studio and other servers on your network 4096, "
                    + "Anthropic 200000, OpenAI 128000. Match what the server has loaded; long transcripts are split, "
                    + "never cut.")
        }
    }

    private var testSection: some View {
        Section {
            Button {
                Task { await test() }
            } label: {
                HStack {
                    Text("Test connection")
                    Spacer()
                    checkBadge
                }
            }
            .disabled(check == .checking || draft.configuration.baseURL == nil)
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                if case .failed(let message) = check {
                    Text(message).foregroundStyle(AppColor.error)
                }
                if let problem = draft.problem {
                    Text(problem).foregroundStyle(AppColor.error)
                }
                Text("Sends a one-word test request with your key. No transcript text.")
            }
        }
    }

    @ViewBuilder private var checkBadge: some View {
        switch check {
        case .idle: EmptyView()
        case .checking: ProgressView()
        case .succeeded:
            Label("Connected", systemImage: "checkmark.circle.fill")
                .foregroundStyle(Tokens.Color.success)
        case .failed:
            Label("Failed", systemImage: "xmark.circle.fill")
                .foregroundStyle(AppColor.error)
        }
    }

    // MARK: - Text

    private var whereItRuns: String {
        guard let host = draft.configuration.host else {
            return "Enter the address, for example http://mac-studio.local:11434 for Ollama on your Mac."
        }
        switch draft.locality {
        case .localNetwork:
            return "Runs on \(host), on your home network. Plain http is fine. iOS asks once for permission to "
                + "reach your network."
        case .cloud:
            return "Runs on \(host), over the internet. Needs https. Clinical transcripts ask before each run."
        case .onDevice:
            return "Runs on this iPhone."
        }
    }

    private var modelHint: String {
        switch draft.kind {
        case .ollama: "For example llama3.1:8b. The model must be pulled in Ollama on your Mac."
        case .openAICompatible: "For example the model id loaded in LM Studio, or gpt-4.1-mini."
        case .anthropic: "For example claude-sonnet-4-5."
        case .appleFoundationModels: ""
        }
    }

    // MARK: - Actions

    private func save() {
        do {
            try environment.languageModels.save(draft)
            dismiss()
        } catch {
            self.error = Formatting.message(for: error)
        }
    }

    private func delete() {
        do {
            try environment.languageModels.delete(providerID: draft.id)
            dismiss()
        } catch {
            self.error = Formatting.message(for: error)
        }
    }

    private func test() async {
        check = .checking
        check = await environment.languageModels.testConnection(draft)
    }

    private func loadModels() async {
        isLoadingModels = true
        defer { isLoadingModels = false }
        do {
            serverModels = try await environment.languageModels.listModels(draft)
            modelsMessage = serverModels.isEmpty ? "The server reported no models." : nil
        } catch {
            modelsMessage = Formatting.message(for: error)
        }
    }
}
