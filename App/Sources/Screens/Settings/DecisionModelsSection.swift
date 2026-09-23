import ChirpCore
import ChirpFeatures
import ChirpUI
import SwiftUI

/// Settings → Models → Decision models (M6a, plan 021): Jev's toggle, its API key and Test connection.
struct DecisionModelsSection: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var isEditingKey = false
    @State private var error: String?

    static let explanation =
        "Jev answers short multiple-choice questions about a transcript. It runs on TypeSafe's servers and never "
        + "receives clinical items."

    var body: some View {
        let jev = environment.jevSettingsModel
        SettingsGroup(title: "Decision models", footer: Self.explanation) {
            SettingsRow(title: "Jev (TypeSafe AI, cloud)", caption: caption(jev)) {
                Toggle("Jev (TypeSafe AI, cloud)", isOn: Binding(get: { jev.isEnabled }, set: { setEnabled($0) }))
                    .labelsHidden()
                    .tint(Tokens.Color.success)
            }
            Button {
                jev.refresh()
                isEditingKey = true
            } label: {
                SettingsRow(
                    title: "Jev API key",
                    caption: jev.hasStoredKey ? "Stored in the Keychain" : "Not added yet"
                ) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Tokens.Color.mutedText)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityHint("Add, replace or test the key")
        }
        .sheet(isPresented: $isEditingKey) { JevKeySheet() }
        .alert(
            "Couldn’t change Jev",
            isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(error ?? "")
        }
    }

    private func caption(_ jev: JevSettingsViewModel) -> String {
        guard jev.isEnabled else { return "Off" }
        let key = jev.hasStoredKey ? "" : " · add a key"
        return "On · \(jev.host) · \(jev.model)\(key)"
    }

    private func setEnabled(_ enabled: Bool) {
        do {
            try environment.jevSettingsModel.setEnabled(enabled)
        } catch {
            self.error = Formatting.message(for: error)
        }
    }
}

/// Jev's key: typed into a secure field (never loaded from the Keychain; a blank field keeps the stored key), removed,
/// or tested with the fixed synthetic sentence.
struct JevKeySheet: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?

    var body: some View {
        @Bindable var jev = environment.jevSettingsModel
        NavigationStack {
            Form {
                Section {
                    SecureField(jev.keyPlaceholder, text: $jev.keyText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityLabel("Jev API key")
                        .onChange(of: jev.keyText) { _, _ in jev.keyEdited() }
                    if jev.hasStoredKey {
                        Toggle("Remove the stored key", isOn: $jev.removesStoredKey)
                            .disabled(!jev.keyText.isEmpty)
                            .onChange(of: jev.removesStoredKey) { _, _ in jev.keyEdited() }
                    }
                } header: {
                    Text("API key")
                } footer: {
                    Text("Kept in this iPhone's Keychain, only on this device, never synced or logged.")
                }
                Section {
                    Button {
                        Task { await jev.testConnection() }
                    } label: {
                        HStack {
                            Text("Test connection")
                            Spacer()
                            checkBadge(jev.check)
                        }
                    }
                    .disabled(jev.check == .checking)
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        if case .failed(let message) = jev.check {
                            Text(message).foregroundStyle(AppColor.error)
                        }
                        Text(
                            "Sends one test question about \u{201C}The quick brown fox jumps over the lazy dog.\u{201D} "
                                + "to \(jev.host). No transcript text.")
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Tokens.Color.ground)
            .navigationTitle("Jev")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        jev.refresh()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") { save() }
                        .bold()
                }
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
        // A swipe-down closes the sheet without Cancel: an unsaved typed key never lingers (review L4 M7).
        .onDisappear { environment.jevSettingsModel.discardTypedKey() }
    }

    @ViewBuilder private func checkBadge(_ check: JevSettingsViewModel.ConnectionCheck) -> some View {
        switch check {
        case .idle: EmptyView()
        case .checking: ProgressView()
        case .succeeded:
            // F80: successInk, not success — success measures 3.06:1 as text, below 4.5:1.
            Label("Connected", systemImage: "checkmark.circle.fill")
                .foregroundStyle(Tokens.Color.successInk)
        case .failed:
            Label("Failed", systemImage: "xmark.circle.fill")
                .foregroundStyle(AppColor.error)
        }
    }

    private func save() {
        do {
            try environment.jevSettingsModel.saveKey()
            dismiss()
        } catch {
            self.error = Formatting.message(for: error)
        }
    }
}
