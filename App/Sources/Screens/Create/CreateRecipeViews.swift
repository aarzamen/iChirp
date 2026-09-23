import ChirpCore
import ChirpFeatures
import ChirpUI
import SwiftUI

// Plan 023 lane 2 (UX audit F14, "Create + recipes"): the recipe tiles on Capture and the Recipes sheet behind their
// Edit button. The recipes themselves, their store and the tap plan are `ChirpFeatures/Create/CreateRecipe.swift`.

/// The short line under a recipe's name.
enum RecipeWords {
    /// Starters keep the old shortcuts' lines; a saved recipe says what it asks for and, with `withModel` (the Recipes
    /// sheet; Capture's tiles stay short), the model it runs on.
    static func subtitle(_ recipe: CreateRecipe, polishAfter: Bool, withModel: Bool = false) -> String {
        switch recipe.starter {
        case .dictate?: return polishAfter ? "Clean text on copy" : "Action Button or tap"
        case .typeOrPaste?: return "Notes, any text"
        case .pasteLink?: return "Podcast, YouTube, web link"
        case .importFile?: return "Voice Memos, audio, PDF, Word"
        case nil: break
        }
        let cue: String =
            switch recipe.choices.input {
            case .speak: "Speak now"
            case .text: "Type or paste"
            case .link: "Paste a link"
            case .file: "Pick a file"
            }
        guard withModel, recipe.needsLanguageModel else { return cue }
        return "\(cue) · \(recipe.modelName ?? "Default model")"
    }

    /// The input's icon (the starters keep the old tiles' icons).
    static func systemImage(_ recipe: CreateRecipe) -> String {
        switch recipe.starter {
        case .dictate?: "waveform"
        case .importFile?: "square.and.arrow.down"
        default: recipe.choices.input.systemImage
        }
    }

    /// What a tap does, for VoiceOver's hint.
    static func hint(_ recipe: CreateRecipe) -> String {
        switch recipe.starter {
        case .dictate?:
            "Starts dictating. Press the Action Button, or tap to go hands-free. The text is copied when you stop."
        case .typeOrPaste?, .pasteLink?, .importFile?: "Opens it."
        case nil:
            switch recipe.choices.input {
            case .speak: "Starts recording now."
            case .text, .link: "Opens Create with this recipe's choices."
            case .file: "Opens Files, then runs the recipe on the file you pick."
            }
        }
    }
}

/// One recipe on Capture: a one-tap tile (at least 72 pt tall) with the input's icon beside the name, a short line and,
/// for a clinical recipe, the Clinical badge. Compact so Recent stays above the fold (F14). VoiceOver reads the whole
/// recipe. Capture lays them out two across, one across from XX Large text.
struct RecipeTile: View {
    let recipe: CreateRecipe
    let subtitle: String
    /// The Dictate starter's coral tile and its text-safe green line while Polish after is on.
    var isAccent = false
    var subtitleIsGreen = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: Tokens.Radius.iconTile, style: .continuous)
                        .fill(isAccent ? Tokens.Color.accent : AppColor.tintFill)
                    Image(systemName: RecipeWords.systemImage(recipe))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(isAccent ? .white : Tokens.Color.accentInk)
                }
                .frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(recipe.name)
                        .chirpFont(15, .semibold)
                        .foregroundStyle(Tokens.Color.ink)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                    // Text-safe green (UX audit F12); `success` is for fills and icons only.
                    Text(subtitle)
                        .chirpFont(12)
                        .foregroundStyle(subtitleIsGreen ? Tokens.Color.privacyBadgeInk : Tokens.Color.secondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                    if recipe.choices.isClinical {
                        PrivacyClassBadge(privacyClass: .clinical)
                            .padding(.top, 3)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: 72, alignment: .topLeading)
            .background(CardBackground(radius: Tokens.Radius.tile))
            .contentShape(RoundedRectangle(cornerRadius: Tokens.Radius.tile, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(recipe.accessibilityLabel))
        .accessibilityHint(Text(RecipeWords.hint(recipe)))
        .accessibilityAddTraits(.isButton)
    }

    /// Two across, or one from XX Large text up, so a name never has to be cut off.
    static func columns(for size: DynamicTypeSize) -> Int {
        size >= .xxLarge ? 1 : 2
    }
}

/// Capture → Recipes → Edit: every recipe in order (the first four show on Capture), to run, rename, reorder or
/// delete; the starters can come back; new ones are saved from Create. Deleting a recipe removes only the recipe,
/// never anything in the Library.
struct RecipesSheet: View {
    let recipes: CreateRecipesViewModel
    /// Runs a recipe once this sheet has gone (Capture does it in the sheet's onDismiss).
    let run: (CreateRecipe) -> Void
    /// Opens Create once this sheet has gone, to save a new recipe there.
    let openCreate: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var editMode: EditMode = .inactive
    @State private var renaming: CreateRecipe?
    @State private var newName = ""
    @State private var deleting: CreateRecipe?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if recipes.recipes.isEmpty {
                        Text("No recipes. Save one from Create, or add back the starters below.")
                            .chirpFont(14)
                            .foregroundStyle(Tokens.Color.secondary)
                    }
                    ForEach(recipes.recipes) { recipe in
                        row(recipe)
                    }
                    .onMove { offsets, destination in
                        var ids = recipes.recipes.map(\.id)
                        ids.move(fromOffsets: offsets, toOffset: destination)
                        recipes.reorder(ids)
                    }
                    .onDelete { offsets in
                        if let index = offsets.first { deleting = recipes.recipes[index] }
                    }
                } footer: {
                    Text(
                        "The first \(CreateRecipesViewModel.captureCount) show on Capture. Tap a recipe to run it; "
                            + "Reorder to choose which ones show."
                    )
                }
                if !recipes.missingStarters.isEmpty, !recipes.isFull {
                    Section {
                        Button("Add back the starter recipes") { recipes.restoreStarters() }
                            .frame(minHeight: 44)
                    } footer: {
                        Text("Dictate, Type or paste, Paste a link and Import a file, as Capture had them.")
                    }
                }
                Section {
                    Button {
                        openCreate()
                        dismiss()
                    } label: {
                        Label("New recipe from Create", systemImage: "plus")
                            .frame(minHeight: 44)
                    }
                    .disabled(recipes.isFull)
                } footer: {
                    Text(
                        recipes.isFull
                            ? "You have \(CreateRecipesViewModel.maxCount) recipes, the most Parakeet keeps. Delete "
                                + "one to save another."
                            : "In Create, choose what you have and what you want, then tap Save as recipe."
                    )
                }
            }
            .environment(\.editMode, $editMode)
            .navigationTitle("Recipes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(editMode.isEditing ? "Finish" : "Reorder") {
                        withAnimation { editMode = editMode.isEditing ? .inactive : .active }
                    }
                    .disabled(recipes.recipes.count < 2 && !editMode.isEditing)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .alert(
                "Rename recipe",
                isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } }),
                presenting: renaming
            ) { recipe in
                TextField("Name", text: $newName)
                Button("Save") { recipes.rename(recipe.id, to: newName) }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("A blank name keeps the old one.")
            }
            .confirmationDialog(
                "Delete “\(deleting?.name ?? "")”?",
                isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                titleVisibility: .visible,
                presenting: deleting
            ) { recipe in
                Button("Delete recipe", role: .destructive) { recipes.delete(recipe.id) }
                Button("Keep it", role: .cancel) {}
            } message: { _ in
                Text("Only the recipe goes. Nothing in your Library changes.")
            }
        }
        .presentationDragIndicator(.visible)
    }

    private func row(_ recipe: CreateRecipe) -> some View {
        let onCapture = recipes.onCapture.contains { $0.id == recipe.id }
        let detail =
            RecipeWords.subtitle(recipe, polishAfter: false, withModel: true) + (onCapture ? " · On Capture" : "")
        return HStack(spacing: 10) {
            Button {
                run(recipe)
                dismiss()
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: RecipeWords.systemImage(recipe))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Tokens.Color.accentInk)
                        .frame(width: 32, height: 32)
                        .background(
                            RoundedRectangle(cornerRadius: Tokens.Radius.iconTile, style: .continuous)
                                .fill(AppColor.tintFill))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(recipe.name)
                            .chirpFont(15.5, .semibold)
                            .foregroundStyle(Tokens.Color.ink)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(detail)
                            .chirpFont(12.5)
                            .foregroundStyle(Tokens.Color.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if recipe.choices.isClinical {
                            PrivacyClassBadge(privacyClass: .clinical)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(editMode.isEditing)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(recipe.accessibilityLabel + (onCapture ? " On Capture." : "")))
            .accessibilityHint(Text("Runs the recipe."))
            .accessibilityAddTraits(.isButton)
            if !editMode.isEditing {
                Menu {
                    Button("Rename", systemImage: "pencil") {
                        newName = recipe.name
                        renaming = recipe
                    }
                    Button("Move up", systemImage: "arrow.up") { recipes.moveUp(recipe.id) }
                        .disabled(!recipes.canMoveUp(recipe.id))
                    Button("Move down", systemImage: "arrow.down") { recipes.moveDown(recipe.id) }
                        .disabled(!recipes.canMoveDown(recipe.id))
                    Button("Delete", systemImage: "trash", role: .destructive) { deleting = recipe }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 20, weight: .regular))
                        .foregroundStyle(AppColor.accentText)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Rename, move or delete \(recipe.spokenName)")
            }
        }
    }
}
