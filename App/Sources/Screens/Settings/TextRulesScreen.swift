import ChirpFeatures
import ChirpText
import ChirpUI
import SwiftUI

/// Settings → Text → Custom words & snippets (M2). Custom words fix how Parakeet writes a word; snippets expand a
/// phrase you say into longer text. Both apply whenever Clean runs (dictation's "Polish after", or the Clean
/// clean-up mode). Swipe a row to delete it; the switch turns one off without deleting it.
struct TextRulesScreen: View {
    let model: TextRulesViewModel
    @State private var editor: Editor?

    /// What the add/edit sheet is editing.
    enum Editor: Identifiable {
        case newWord, word(CustomWord), newSnippet, snippet(TextSnippet)

        var id: String {
            switch self {
            case .newWord: "new-word"
            case .word(let word): "word-\(word.id)"
            case .newSnippet: "new-snippet"
            case .snippet(let snippet): "snippet-\(snippet.id)"
            }
        }
    }

    var body: some View {
        List {
            Section {
                if model.words.isEmpty {
                    emptyRow("No custom words yet. Add a name, a brand or a term Parakeet gets wrong.")
                }
                ForEach(model.words) { word in
                    wordRow(word)
                }
                .onDelete { offsets in
                    let ids = Set(offsets.map { model.words[$0].id })
                    Task { await model.deleteWords(ids) }
                }
                Button("Add word", systemImage: "plus") { editor = .newWord }
                    .foregroundStyle(AppColor.accentText)
            } header: {
                Text("Custom words")
            } footer: {
                Text("Parakeet writes the word exactly as you typed it, or its replacement when you give one.")
            }

            Section {
                if model.snippets.isEmpty {
                    emptyRow("No snippets yet. Say a short phrase, get your address or sign-off.")
                }
                ForEach(model.snippets) { snippet in
                    snippetRow(snippet)
                }
                .onDelete { offsets in
                    let ids = Set(offsets.map { model.snippets[$0].id })
                    Task { await model.deleteSnippets(ids) }
                }
                Button("Add snippet", systemImage: "plus") { editor = .newSnippet }
                    .foregroundStyle(AppColor.accentText)
            } header: {
                Text("Snippets")
            } footer: {
                Text(
                    "Custom words and snippets apply when Clean runs: “Polish after” on a dictation, or Clean in "
                        + "Settings → Text for every transcription.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(Tokens.Color.ground)
        .navigationTitle("Custom words & snippets")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .task { await model.load() }
        .sheet(item: $editor) { editor in
            TextRuleEditorSheet(model: model, editor: editor)
        }
        .alert(
            "Couldn’t save that",
            isPresented: Binding(
                get: { model.lastError != nil && editor == nil }, set: { if !$0 { model.dismissError() } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.lastError ?? "")
        }
    }

    private func emptyRow(_ text: String) -> some View {
        Text(text)
            .chirpFont(13.5)
            .foregroundStyle(Tokens.Color.secondary)
    }

    private func wordRow(_ word: CustomWord) -> some View {
        HStack(spacing: 10) {
            Button {
                editor = .word(word)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(word.word)
                        .chirpFont(15.5, .semibold)
                        .foregroundStyle(Tokens.Color.ink)
                    Text(word.replacement.map { "Writes “\($0)”" } ?? "Fixes spelling and capitals")
                        .chirpFont(12.5)
                        .foregroundStyle(Tokens.Color.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Toggle(
                "On",
                isOn: Binding(
                    get: { word.isEnabled },
                    set: { isOn in
                        var edited = word
                        edited.isEnabled = isOn
                        Task { await model.update(edited) }
                    })
            )
            .labelsHidden()
            .tint(Tokens.Color.success)
            .accessibilityLabel("\(word.word) on")
        }
    }

    private func snippetRow(_ snippet: TextSnippet) -> some View {
        HStack(spacing: 10) {
            Button {
                editor = .snippet(snippet)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("“\(snippet.trigger)”")
                        .chirpFont(15.5, .semibold)
                        .foregroundStyle(Tokens.Color.ink)
                    Text(snippet.expansion)
                        .chirpFont(12.5)
                        .foregroundStyle(Tokens.Color.secondary)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Toggle(
                "On",
                isOn: Binding(
                    get: { snippet.isEnabled },
                    set: { isOn in
                        var edited = snippet
                        edited.isEnabled = isOn
                        Task { await model.update(edited) }
                    })
            )
            .labelsHidden()
            .tint(Tokens.Color.success)
            .accessibilityLabel("\(snippet.trigger) on")
        }
    }
}

/// Add or edit one custom word or snippet. Save stays disabled until the required fields have text; a duplicate
/// shows its message here and keeps the sheet open.
private struct TextRuleEditorSheet: View {
    let model: TextRulesViewModel
    let editor: TextRulesScreen.Editor
    @Environment(\.dismiss) private var dismiss
    @State private var first = ""
    @State private var second = ""
    @State private var isSaving = false

    private var isWord: Bool {
        switch editor {
        case .newWord, .word: true
        case .newSnippet, .snippet: false
        }
    }

    private var canSave: Bool {
        let hasFirst = !first.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasSecond = !second.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return isWord ? hasFirst : hasFirst && hasSecond
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(isWord ? "Word, as it should be written" : "What you say", text: $first)
                        .textInputAutocapitalization(isWord ? .never : .sentences)
                        .autocorrectionDisabled()
                    TextField(
                        isWord ? "Replacement (optional)" : "What Parakeet writes", text: $second, axis: .vertical
                    )
                    .lineLimit(isWord ? 1...2 : 2...6)
                } footer: {
                    Text(
                        isWord
                            ? "Example: “kubernetes” with the replacement “Kubernetes”. Without a replacement the word "
                                + "is written exactly as typed."
                            : "Example: say “my address” and Parakeet writes your full address.")
                }
                if let error = model.lastError {
                    Section {
                        Text(error)
                            .foregroundStyle(AppColor.error)
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        model.dismissError()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(!canSave || isSaving)
                }
            }
            .onAppear(perform: fill)
        }
        .presentationDetents([.medium, .large])
    }

    private var title: String {
        switch editor {
        case .newWord: "Add word"
        case .word: "Edit word"
        case .newSnippet: "Add snippet"
        case .snippet: "Edit snippet"
        }
    }

    private func fill() {
        switch editor {
        case .word(let word):
            first = word.word
            second = word.replacement ?? ""
        case .snippet(let snippet):
            first = snippet.trigger
            second = snippet.expansion
        case .newWord, .newSnippet:
            break
        }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        model.dismissError()
        let saved: Bool
        switch editor {
        case .newWord:
            saved = await model.addWord(first, replacement: second)
        case .word(var word):
            word.word = first
            word.replacement = second
            saved = await model.update(word)
        case .newSnippet:
            saved = await model.addSnippet(trigger: first, expansion: second)
        case .snippet(var snippet):
            snippet.trigger = first
            snippet.expansion = second
            saved = await model.update(snippet)
        }
        if saved { dismiss() }
    }
}
