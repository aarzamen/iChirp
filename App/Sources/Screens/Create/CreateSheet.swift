import ChirpCore
import ChirpFeatures
import ChirpIngest
import ChirpUI
import SwiftUI

/// Where the Create sheet's own navigation goes: the item or the document a chain made.
enum CreateDestination: Hashable {
    case item(UUID)
    case document(UUID)
}

/// Capture → Create (plan 022 Step 3): two questions, "What do you have?" (Speak · Type or paste · Link · File) and
/// "What do you want?" (Transcript · Summary · Document ▸ template · Voice message), then the chain's real progress
/// and result in the same sheet. The last answers are remembered. Anything that cannot run says why before Create is
/// tapped (no speech model, no language model, no voice); clinical steps ask through the existing dialogs. Typed text or
/// a pasted link is never lost: swipe-down is off while there is some, Cancel asks first, and a sheet hidden by
/// something else (the Action Button's dictation) keeps it for the next open (UX audit F19).
///
/// Plan 023 lane 2 (UX audit F14): "Save as recipe" keeps these choices (and the model, when the output needs one) as a
/// one-tap recipe on Capture, with a suggested name the person can change. A Type or Link recipe opens this sheet with
/// its own choices and model, and says so at the top.
struct CreateSheet: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dynamicTypeSize) private var typeSize
    let host: CreateHost

    @State private var draft: CreateDraft
    @State private var choice: LanguageModelChoice
    @State private var path: [CreateDestination] = []
    @State private var isPickingFile = false
    @State private var pickerError: String?
    @State private var isConfirmingDiscard = false
    /// Cancel → Discard: the sheet goes and its text is not kept.
    @State private var isDiscarding = false
    /// The recipe this sheet was opened from (Type or Link), for its note; nil for a plain Create.
    @State private var recipe: CreateRecipe?
    /// "Save as recipe": the name being typed, and the recipe just saved from here.
    @State private var isNamingRecipe = false
    @State private var recipeName = ""
    @State private var savedRecipeID: UUID?
    @FocusState private var textFocused: Bool
    @FocusState private var linkFocused: Bool

    private let choicesStore = UserDefaultsCreateChoicesStore()

    init(host: CreateHost, environment: AppEnvironment) {
        self.host = host
        let remembered = UserDefaultsCreateChoicesStore().load()
        let templateIDs = Set(
            (environment.deliverableLibrary.documentTemplates + environment.deliverableLibrary.transformTemplates)
                .map(\.id))
        // A recipe's choices win over the last answers (plan 023 lane 2).
        let recipe = host.pendingRecipe
        let choices = recipe?.choices ?? remembered
        var initial = CreateDraft(
            choices: templateIDs.isEmpty ? choices : choices.validated(templateIDs: templateIDs))
        initial.file = CreatePreviewLaunch.file()  // DEBUG tour only; always nil in Release
        if recipe != nil, let kept = host.keptDraft {
            // Text or a link typed before, and kept when the sheet went away, is not lost to the recipe (F19).
            initial.text = kept.text
            initial.link = kept.link
            _draft = State(initialValue: initial)
        } else {
            // What was typed when the sheet last went away without a Discard (cleared in onAppear, once it is shown).
            _draft = State(initialValue: host.keptDraft ?? initial)
        }
        _recipe = State(initialValue: recipe)
        let models = environment.languageModels
        _choice = State(initialValue: recipe?.modelID.flatMap(models.choice(id:)) ?? models.defaultChoice)
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if let flow = host.flow, let request = host.request {
                    CreateRunView(
                        host: host, flow: flow, request: request, choice: choice,
                        outputTitle: outputTitle(for: request.output),
                        open: { path.append($0) })
                } else {
                    questions
                }
            }
            .navigationDestination(for: CreateDestination.self) { destination in
                switch destination {
                case .item(let id): LibraryItemScreen(id: id, environment: environment)
                case .document(let id): DeliverableDetailScreen(id: id, environment: environment)
                }
            }
        }
        .tint(AppColor.accentText)
        .discardInputConfirmation(
            "Discard what you typed?", message: "The text or link you entered here is not kept.",
            hasInput: host.flow == nil && draft.hasUnsavedInput, isAsking: $isConfirmingDiscard
        ) {
            isDiscarding = true
            host.keptDraft = nil
            host.hide()
        }
        // The operation's per-run question and the voice message's: only their dialogs answer (spec/12).
        .clinicalConfirmation(for: host.flow?.operationRun)
        .voiceMessageConfirmation(for: host.flow?.voiceMessage as? VoiceMessageExporter)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .fileImporter(isPresented: $isPickingFile, allowedContentTypes: CreateFileTypes.all) { result in
            switch result {
            case .success(let url): draft.file = url
            case .failure(let error): pickerError = Formatting.message(for: error)
            }
        }
        .task {
            await environment.languageModels.refresh()
            await environment.voiceSettings.refresh()
        }
        .onChange(of: draft.choices) { _, choices in choicesStore.save(choices) }
        .onAppear {
            host.keptDraft = nil
            host.pendingRecipe = nil
        }
        .onDisappear {
            // Hidden by something other than Cancel → Discard while text was typed: keep it for the next open.
            if host.flow == nil, !isDiscarding, draft.hasUnsavedInput { host.keptDraft = draft }
        }
    }

    // MARK: - Questions

    private var questions: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Create")
                        .chirpTitleFont(26, .heavy)
                        .foregroundStyle(Tokens.Color.ink)
                        .accessibilityAddTraits(.isHeader)
                    Text("Anything in, anything out. Each step below says where it runs.")
                        .chirpFont(13)
                        .foregroundStyle(Tokens.Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let recipe {
                    CreateNote(
                        text: "From your recipe “\(recipe.name)”. "
                            + (recipe.choices.input == .link ? "Paste the link" : "Type or paste the text")
                            + ", then tap Create.",
                        systemImage: "bookmark")
                }
                SectionLabel("What do you have?")
                    .padding(.top, 6)
                grid(CreateInputKind.allCases) { kind in
                    CreateOptionTile(
                        title: kind.title, subtitle: kind.subtitle, systemImage: kind.systemImage,
                        isSelected: draft.input == kind
                    ) { select(kind) }
                }
                inputDetail
                SectionLabel("What do you want?")
                    .padding(.top, 8)
                grid(CreateChoices.OutputKind.allCases) { kind in
                    CreateOptionTile(
                        title: kind.title, subtitle: kind.subtitle, systemImage: kind.systemImage,
                        isSelected: draft.output == kind
                    ) {
                        draft.output = kind
                        // The first question is answered: the keyboard goes, so the template, model, Clinical and
                        // Save as recipe below are in view (with the keyboard up the start bar covers them).
                        textFocused = false
                        linkFocused = false
                    }
                }
                outputDetail
                ClinicalToggleRow(isClinical: $draft.isClinical)
                    .padding(.top, 4)
                saveRecipeRow
            }
            .padding(.horizontal, 24)
            .padding(.top, 8)
            .padding(.bottom, 16)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Tokens.Color.ground)
        .safeAreaInset(edge: .bottom, spacing: 0) { startBar }
        .task {
            // A Type or Link recipe: the field it needs is ready to type in once the sheet is up.
            guard let recipe, recipe.choices.input == .text || recipe.choices.input == .link else { return }
            try? await Task.sleep(for: .milliseconds(450))
            textFocused = recipe.choices.input == .text
            linkFocused = recipe.choices.input == .link && draft.link.isEmpty
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    switch DiscardDecision.onCancel(hasInput: draft.hasUnsavedInput) {
                    case .close: host.hide()
                    case .ask: isConfirmingDiscard = true
                    }
                }
            }
        }
        .alert(
            "Couldn’t open the file picker",
            isPresented: Binding(get: { pickerError != nil }, set: { if !$0 { pickerError = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(pickerError ?? "")
        }
    }

    private func grid<Item: Hashable, Tile: View>(_ items: [Item], @ViewBuilder tile: @escaping (Item) -> Tile)
        -> some View
    {
        let columns = Array(
            repeating: GridItem(.flexible(), spacing: 10), count: CreateOptionTile.columns(for: typeSize))
        return LazyVGrid(columns: columns, spacing: 10) {
            ForEach(items, id: \.self) { tile($0) }
        }
    }

    private func select(_ kind: CreateInputKind) {
        draft.input = kind
        textFocused = kind == .text
        linkFocused = kind == .link && draft.link.isEmpty
    }

    // MARK: Input detail

    @ViewBuilder private var inputDetail: some View {
        switch draft.input {
        case .speak:
            if environment.isSpeechModelReady {
                CreateNote(
                    text:
                        "The Dictating screen opens next. Tap Stop & copy when you are done; Parakeet then continues here.",
                    systemImage: "waveform")
            } else {
                CreateNote(
                    text: "Download the speech model in Settings → Speech first. It runs on this iPhone.",
                    systemImage: "arrow.down.circle", isProblem: true)
            }
        case .text:
            TextEntryCard(
                text: $draft.text, placeholder: "Type or paste text. The first line becomes its title.",
                focused: $textFocused, minHeight: 130)
        case .link:
            linkField
        case .file:
            fileRow
        }
    }

    private var linkField: some View {
        let kind = LinkClassifier.classify(draft.link)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "link")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Tokens.Color.secondary)
                    .accessibilityHidden(true)
                TextField("Podcast, YouTube or web link", text: $draft.link, axis: .vertical)
                    .chirpFont(15)
                    .lineLimit(1...3)
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($linkFocused)
                PasteButton(payloadType: String.self) { strings in
                    guard let pasted = strings.first else { return }
                    Task { @MainActor in draft.link = pasted.trimmingCharacters(in: .whitespacesAndNewlines) }
                }
                .labelStyle(.iconOnly)
                .buttonBorderShape(.capsule)
                .tint(Tokens.Color.accentInk)
            }
            .padding(12)
            .background(CardBackground(radius: Tokens.Radius.s))
            if !draft.link.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: kind.isActionable ? "checkmark.circle.fill" : "exclamationmark.circle")
                        .foregroundStyle(kind.isActionable ? Tokens.Color.success : AppColor.error)
                        .accessibilityHidden(true)
                    Text(kind.isActionable ? "\(kind.title). \(kind.detail)" : kind.detail)
                        .chirpFont(12.5)
                        .foregroundStyle(Tokens.Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 4)
            }
        }
    }

    private var fileRow: some View {
        Button {
            isPickingFile = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: draft.file == nil ? "folder" : "doc.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Tokens.Color.accentInk)
                    .frame(width: 34, height: 34)
                    .background(
                        RoundedRectangle(cornerRadius: Tokens.Radius.iconTile, style: .continuous)
                            .fill(AppColor.tintFill)
                    )
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(draft.file?.lastPathComponent ?? "Choose a file")
                        .chirpFont(15, .semibold)
                        .foregroundStyle(Tokens.Color.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(
                        draft.file == nil
                            ? "Audio, video, PDF, Word or text from Files" : "Tap to choose another file"
                    )
                    .chirpFont(12)
                    .foregroundStyle(Tokens.Color.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Tokens.Color.mutedText)
                    .accessibilityHidden(true)
            }
            .padding(12)
            .background(CardBackground(radius: Tokens.Radius.s))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Output detail

    @ViewBuilder private var outputDetail: some View {
        switch draft.output {
        case .transcript:
            EmptyView()
        case .summary:
            modelRow
        case .document:
            templateMenu
            modelRow
        case .voiceMessage:
            Picker("Speak", selection: $draft.voiceSummarizeFirst) {
                Text("The whole text").tag(false)
                Text("A summary").tag(true)
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("What the voice message says")
            voiceRow
            if draft.voiceSummarizeFirst { modelRow }
        }
    }

    private var templates: [PromptTemplate] {
        environment.deliverableLibrary.documentTemplates + environment.deliverableLibrary.transformTemplates
    }

    /// Documents and rewrites in their own sections, as the Transform sheet lists them (UX audit F20).
    private var templateMenu: some View {
        let selected = templates.first { $0.id == draft.templateID }
        let library = environment.deliverableLibrary
        return Menu {
            Picker("Template", selection: $draft.templateID) {
                Section("Documents") {
                    ForEach(library.documentTemplates) { template in
                        Text(template.name).tag(Optional(template.id))
                    }
                }
                Section("Rewrites") {
                    ForEach(library.transformTemplates) { template in
                        Text(template.name).tag(Optional(template.id))
                    }
                }
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "doc.richtext")
                    .foregroundStyle(Tokens.Color.accentInk)
                    .accessibilityHidden(true)
                Text(selected.map { "Template: \($0.name)" } ?? "Choose a template")
                    .chirpFont(15, .semibold)
                    .foregroundStyle(selected == nil ? AppColor.accentText : Tokens.Color.ink)
                Spacer(minLength: 0)
                if selected?.outputPrivacyClass == .clinical {
                    PrivacyClassBadge(privacyClass: .clinical)
                }
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Tokens.Color.secondary)
                    .accessibilityHidden(true)
            }
            .padding(12)
            .frame(minHeight: 48)
            .background(CardBackground(radius: Tokens.Radius.s))
        }
        .accessibilityLabel(selected.map { "Template: \($0.name)" } ?? "Choose a template")
    }

    private var modelRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            ModelChoiceMenu(prefix: "Runs", choice: $choice)
            if let message = environment.unavailableMessage(for: choice) {
                ModelUnavailableNote(message: message)
            } else if !choice.isTrustedForClinical {
                Text(
                    draft.isClinical
                        ? "Clinical: Parakeet will ask before anything is sent to \(choice.name)."
                        : "Clinical items and SOAP notes ask before anything is sent to \(choice.name)."
                )
                .chirpFont(12.5)
                .foregroundStyle(Tokens.Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private var voiceRow: some View {
        let voices = environment.voiceSettings
        if let problem = voices.setupProblem {
            CreateNote(text: problem, systemImage: "speaker.slash", isProblem: true)
        } else if let provider = voices.settings.provider {
            CreateNote(
                text: "Spoken by \(provider.displayName) (\(provider.place.lowercasedFirst)). "
                    + (draft.isClinical || provider == .xai
                        ? "Clinical text asks before it is sent." : "Saved with the item as an audio file."),
                systemImage: "speaker.wave.2")
        }
    }

    // MARK: - Save as recipe (plan 023 lane 2)

    private var recipeTemplateName: String? {
        guard draft.output == .document else { return nil }
        return templates.first { $0.id == draft.templateID }?.name
    }

    /// The model kept with a recipe: the chosen one, when the output needs one.
    private var recipeModel: LanguageModelChoice? {
        draft.choices.createOutput?.needsLanguageModel == true ? choice : nil
    }

    /// "Save as recipe" and one line that says what it will do, or why it cannot (no template yet, already a recipe,
    /// the list is full).
    private var saveRecipeRow: some View {
        let recipes = host.recipes
        let choices = draft.choices
        let existing = recipes.existing(choices: choices, modelID: recipeModel?.id)
        let canSave = choices.createOutput != nil && existing == nil && !recipes.isFull
        let note: String =
            if choices.createOutput == nil {
                "Choose a template first."
            } else if let existing, existing.id == savedRecipeID {
                "Saved. “\(existing.name)” is first on Capture."
            } else if let existing {
                "Already a recipe: “\(existing.name)”."
            } else if recipes.isFull {
                "You have \(CreateRecipesViewModel.maxCount) recipes. Delete one in Capture → Recipes first."
            } else {
                "These choices as one tap on Capture. Never the text, link or file."
            }
        let row = HStack(spacing: 12) {
            Image(systemName: existing == nil ? "bookmark" : "bookmark.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Tokens.Color.accentInk)
                .frame(width: 34, height: 34)
                .background(
                    RoundedRectangle(cornerRadius: Tokens.Radius.iconTile, style: .continuous)
                        .fill(AppColor.tintFill)
                )
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Save as recipe")
                    .chirpFont(15, .semibold)
                    .foregroundStyle(canSave ? Tokens.Color.ink : Tokens.Color.secondary)
                Text(note)
                    .chirpFont(12)
                    .foregroundStyle(Tokens.Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
        .background(CardBackground(radius: Tokens.Radius.s))
        .contentShape(Rectangle())
        return Group {
            if canSave {
                Button {
                    recipeName = CreateRecipe.suggestedName(for: choices, templateName: recipeTemplateName)
                    isNamingRecipe = true
                } label: {
                    row
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityHint("Names these choices as a recipe for Capture.")
            } else {
                // Not a dimmed button: the line says why at full contrast.
                row.accessibilityElement(children: .combine)
            }
        }
        .padding(.top, 4)
        .alert("Save as recipe", isPresented: $isNamingRecipe) {
            TextField("Name", text: $recipeName)
            Button("Save") { saveRecipe() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(recipeAlertMessage)
        }
    }

    /// The whole recipe in words, so the person knows what one tap will do.
    private var recipeAlertMessage: String {
        let preview = CreateRecipe(
            name: "", choices: draft.choices, modelName: recipeModel?.name, templateName: recipeTemplateName)
        return "\(preview.spokenDescription) It goes first on Capture."
    }

    private func saveRecipe() {
        let result = host.recipes.save(
            name: recipeName, choices: draft.choices, modelID: recipeModel?.id, modelName: recipeModel?.name,
            templateName: recipeTemplateName)
        if case .saved(let saved) = result { savedRecipeID = saved.id }
    }

    // MARK: - Start

    private var startBar: some View {
        let problem = CreateReadiness.problem(
            draft, speechModelReady: environment.isSpeechModelReady,
            modelProblem: environment.unavailableMessage(for: choice),
            voiceProblem: environment.voiceSettings.setupProblem)
        return VStack(spacing: 6) {
            if let problem, !isShownInline(problem) {
                Text(problem)
                    .chirpFont(12.5)
                    .foregroundStyle(Tokens.Color.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button {
                start()
            } label: {
                Label(
                    draft.input == .speak ? "Start speaking" : "Create",
                    systemImage: draft.input == .speak ? "mic.fill" : "sparkles"
                )
                .chirpFont(16, .bold)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 50)
                .background(Capsule().fill(problem == nil ? Tokens.Color.accentInk : Tokens.Color.mutedText))
            }
            .buttonStyle(.plain)
            .disabled(problem != nil)
        }
        .padding(.horizontal, 24)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(
            Tokens.Color.ground
                .overlay(alignment: .top) { Rectangle().fill(Tokens.Color.border).frame(height: 1) }
                .ignoresSafeArea(edges: .bottom))
    }

    /// The notes above already say it (the speech model, the voice, Apple's model): the bar does not repeat it.
    private func isShownInline(_ problem: String) -> Bool {
        (draft.input == .speak && !environment.isSpeechModelReady)
            || problem == environment.voiceSettings.setupProblem
            || problem == environment.unavailableMessage(for: choice)
    }

    private func start() {
        guard let request = draft.request else { return }
        // A recipe's own choices are not Create's last answers; anything changed here is.
        if recipe?.choices != draft.choices { choicesStore.save(draft.choices) }
        textFocused = false
        linkFocused = false
        host.start(
            request, choice: choice, outputTitle: outputTitle(for: request.output), environment: environment)
    }

    private func outputTitle(for output: CreateOutput) -> String {
        CreateReadiness.outputTitle(for: output, templates: templates)
    }
}

extension String {
    /// "Your Mac, over…" → "your Mac, over…".
    var lowercasedFirst: String {
        prefix(1).lowercased() + dropFirst()
    }
}
