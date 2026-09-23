import ChirpCore
import ChirpFeatures
import ChirpUI
import SwiftUI

/// Capture → Type or paste (plan 022 Step 1): a plain editor that saves typed or pasted text as a Library item. The
/// first line becomes its title. Nothing leaves the phone; the item then works everywhere a transcript does.
struct TextItemSheet: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    /// Opens the saved item (the sheet closes first).
    let onSaved: (UUID) -> Void

    @State private var text = ""
    @State private var isClinical = false
    @State private var isSaving = false
    @State private var error: String?
    @FocusState private var editorFocused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    TextEntryCard(
                        text: $text, placeholder: "Type or paste text. The first line becomes its title.",
                        focused: $editorFocused)
                    ClinicalToggleRow(isClinical: $isClinical)
                    if let error {
                        Text(error)
                            .chirpFont(13)
                            .foregroundStyle(AppColor.error)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text(
                        "Saved in your Library on this iPhone. Transform, Ask, Listen and Create work on it like on a transcript."
                    )
                    .chirpFont(12.5)
                    .foregroundStyle(Tokens.Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 24)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Tokens.Color.ground)
            .navigationTitle("Type or paste")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .bold()
                        .disabled(isSaving || TextItemService.normalized(text).isEmpty)
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .onAppear { editorFocused = true }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        do {
            let item = try await TextItemService(store: environment.store)
                .save(text, privacyClass: isClinical ? .clinical : .personal)
            dismiss()
            onSaved(item.id)
        } catch {
            self.error = Formatting.message(for: error)
        }
    }
}

/// A card with a multi-line editor, a placeholder, Paste and Clear, and a word count. Shared by Type or paste and
/// the Create sheet.
struct TextEntryCard: View {
    @Binding var text: String
    let placeholder: String
    var focused: FocusState<Bool>.Binding
    var minHeight: CGFloat = 220

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder)
                        .chirpFont(16)
                        .foregroundStyle(Tokens.Color.mutedText)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 8)
                        .accessibilityHidden(true)
                }
                TextEditor(text: $text)
                    .chirpFont(16)
                    .foregroundStyle(Tokens.Color.ink)
                    .scrollContentBackground(.hidden)
                    .focused(focused)
                    .frame(minHeight: minHeight)
                    .accessibilityLabel("Text")
            }
            .padding(.horizontal, 10)
            .padding(.top, 6)
            Rectangle().fill(AppColor.quietFill).frame(height: 1)
            HStack(spacing: 10) {
                // PasteButton reads the clipboard only when tapped, so iOS shows no paste-permission prompt.
                PasteButton(payloadType: String.self) { strings in
                    guard let pasted = strings.first else { return }
                    Task { @MainActor in
                        text = text.isEmpty ? pasted : text + (text.hasSuffix("\n") ? "" : "\n") + pasted
                    }
                }
                .buttonBorderShape(.capsule)
                .labelStyle(.titleAndIcon)
                .tint(Tokens.Color.accentInk)
                .controlSize(.small)
                if !text.isEmpty {
                    Button("Clear") { text = "" }
                        .chirpFont(13.5, .semibold)
                        .foregroundStyle(AppColor.accentText)
                        .frame(minHeight: 32)
                }
                Spacer(minLength: 8)
                Text(Self.countLabel(text))
                    .chirpFont(12)
                    .monospacedDigit()
                    .foregroundStyle(Tokens.Color.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(CardBackground(radius: Tokens.Radius.m))
    }

    /// "0 words", "1 word", "1,204 words".
    static func countLabel(_ text: String) -> String {
        let words = DocumentRow.wordCount(text)
        return words == 1 ? "1 word" : "\(words.formatted()) words"
    }
}

/// "Clinical (patient information)": a new item is saved as clinical from the start, so every step that could leave
/// the phone asks first. Off saves it as personal (the default class).
struct ClinicalToggleRow: View {
    @Binding var isClinical: Bool

    var body: some View {
        Toggle(isOn: $isClinical) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Clinical (patient information)")
                    .chirpFont(15, .semibold)
                    .foregroundStyle(Tokens.Color.ink)
                Text(
                    isClinical
                        ? "Stays on this iPhone. Parakeet asks before any step would send it to a cloud or untrusted model or voice."
                        : "Saved as personal. Mark it clinical if it holds patient information."
                )
                .chirpFont(12.5)
                .foregroundStyle(Tokens.Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .tint(Tokens.Color.success)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(CardBackground(radius: Tokens.Radius.s))
    }
}
