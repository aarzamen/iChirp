import ChirpFeatures
import ChirpText
import ChirpUI
import SwiftUI

/// Settings → Text → Custom words & snippets (M2). Custom words fix how Parakeet writes a word; snippets expand a
/// phrase you say into longer text. Both apply whenever Clean runs (dictation's "Polish after", or the Clean
/// clean-up mode). Swipe a row to delete it (it asks first: a long snippet is hard to type again; review R6b-5); the
/// switch turns one off without deleting it. Plan 025 Part B: "Fixes from your corrections" lists the learned rules a
/// Replace saved ("Also fix … in future transcripts"); new transcripts get them as corrections, in Raw and Clean.
struct TextRulesScreen: View {
    let model: TextRulesViewModel
    @State private var editor: Editor?
    /// The row a swipe asked to delete, waiting for the confirmation.
    @State private var deleting: Deletion?

    /// A custom word or snippet waiting for "Delete …?".
    enum Deletion: Identifiable {
        case word(CustomWord)
        case rule(CustomWord)
        case snippet(TextSnippet)

        var id: String {
            switch self {
            case .word(let word): "word-\(word.id)"
            case .rule(let rule): "rule-\(rule.id)"
            case .snippet(let snippet): "snippet-\(snippet.id)"
            }
        }

        /// "Delete “kubernetes”?" / "Delete the snippet “my address”?"
        var question: String {
            switch self {
            case .word(let word): "Delete “\(word.word)”?"
            case .rule(let rule): "Delete the fix for “\(rule.word)”?"
            case .snippet(let snippet): "Delete the snippet “\(snippet.trigger)”?"
            }
        }

        var buttonTitle: String {
            switch self {
            case .word: "Delete Word"
            case .rule: "Delete Fix"
            case .snippet: "Delete Snippet"
            }
        }
    }

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
                if model.manualWords.isEmpty {
                    emptyRow("No custom words yet. Add a name, a brand or a term Parakeet gets wrong.")
                }
                ForEach(model.manualWords) { word in
                    wordRow(word)
                }
                // A full swipe asks first (R6b-5), as Recipes and the Library do.
                .onDelete { offsets in
                    if let index = offsets.first { deleting = .word(model.manualWords[index]) }
                }
                Button("Add word", systemImage: "plus") { editor = .newWord }
                    .foregroundStyle(AppColor.accentText)
            } header: {
                Text("Custom words")
            } footer: {
                Text("Parakeet writes the word exactly as you typed it, or its replacement when you give one.")
            }
            .listRowBackground(Tokens.Color.surface)

            Section {
                if model.snippets.isEmpty {
                    emptyRow("No snippets yet. Say a short phrase, get your address or sign-off.")
                }
                ForEach(model.snippets) { snippet in
                    snippetRow(snippet)
                }
                .onDelete { offsets in
                    if let index = offsets.first { deleting = .snippet(model.snippets[index]) }
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
            .listRowBackground(Tokens.Color.surface)

            // Plan 025 D8: learned rules, saved from a Replace. They never run in Clean; new transcripts get them as
            // corrections the person can see and undo.
            Section {
                if model.learnedRules.isEmpty {
                    emptyRow(TextRulesCopy.learnedEmpty)
                }
                ForEach(model.learnedRules) { rule in
                    wordRow(rule)
                }
                .onDelete { offsets in
                    if let index = offsets.first { deleting = .rule(model.learnedRules[index]) }
                }
            } header: {
                Text(TextRulesCopy.learnedHeader)
            } footer: {
                Text(TextRulesCopy.learnedFooter)
            }
            .listRowBackground(Tokens.Color.surface)
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
        .confirmationDialog(
            deleting?.question ?? "",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible, presenting: deleting
        ) { deletion in
            Button(deletion.buttonTitle, role: .destructive) { delete(deletion) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("It is removed for good. To stop using it for now, turn its switch off instead.")
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

    private func delete(_ deletion: Deletion) {
        deleting = nil
        Task {
            switch deletion {
            case .word(let word), .rule(let word): await model.deleteWords([word.id])
            case .snippet(let snippet): await model.deleteSnippets([snippet.id])
            }
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
            .toggleStyle(.chirpSwitch)
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
            .toggleStyle(.chirpSwitch)
            .accessibilityLabel("\(snippet.trigger) on")
        }
    }
}

/// Add or edit one custom word or snippet. Save stays disabled until the required fields have text; a duplicate
/// shows its message here and keeps the sheet open. Typed text is never lost to a dismissal (R6b-5, F19/F24): while
/// something was typed or changed, swipe-down is off and Cancel asks first.
struct TextRuleEditorSheet: View {
    let model: TextRulesViewModel
    let editor: TextRulesScreen.Editor
    @Environment(\.dismiss) private var dismiss
    @State private var first = ""
    @State private var second = ""
    @State private var isSaving = false
    @State private var isConfirmingCancel = false

    /// The two fields as the sheet opened (empty for a new word or snippet).
    static func original(_ editor: TextRulesScreen.Editor) -> (first: String, second: String) {
        switch editor {
        case .word(let word): (word.word, word.replacement ?? "")
        case .snippet(let snippet): (snippet.trigger, snippet.expansion)
        case .newWord, .newSnippet: ("", "")
        }
    }

    /// Closing now would lose something typed: a field differs from how the sheet opened, ignoring spaces at the ends.
    static func hasChanges(_ editor: TextRulesScreen.Editor, first: String, second: String) -> Bool {
        let original = original(editor)
        func same(_ a: String, _ b: String) -> Bool {
            a.trimmingCharacters(in: .whitespacesAndNewlines) == b.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return !same(first, original.first) || !same(second, original.second)
    }

    private var hasChanges: Bool { Self.hasChanges(editor, first: first, second: second) }

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
                    ChirpTextField(isWord ? "Word, as it should be written" : "What you say", text: $first)
                        .textInputAutocapitalization(isWord ? .never : .sentences)
                        .autocorrectionDisabled()
                    ChirpTextField(
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
                        switch DiscardDecision.onCancel(hasInput: hasChanges) {
                        case .close: close()
                        case .ask: isConfirmingCancel = true
                        }
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
        .discardInputConfirmation(
            "Discard your changes?", message: "What you typed here is not saved.", hasInput: hasChanges,
            isAsking: $isConfirmingCancel
        ) { close() }
    }

    private func close() {
        model.dismissError()
        dismiss()
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
        (first, second) = Self.original(editor)
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

/// The words of the "Fixes from your corrections" section (plan 025 D5).
enum TextRulesCopy {
    static let learnedHeader = "Fixes from your corrections"
    static let learnedFooter =
        "Parakeet makes these fixes in new transcripts as corrections you can see and undo, in Raw and Clean. The words "
        + "it heard are kept."
    static let learnedEmpty =
        "None yet. After you replace a word in a transcript with Find, Parakeet can fix it in new transcripts too."
}
