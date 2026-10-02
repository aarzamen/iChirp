import ChirpCore
import ChirpFeatures
import ChirpUI
import SwiftUI

// Plan 026 Step 7: the template editor (a Form sheet like the provider editor), and the one way every screen opens it
// (`.templateEditor($request)`), which also runs "Save and try…" after the editor has gone. The rules and sentences are
// `TemplateEditorViewModel` / `TemplateDraft` in ChirpFeatures; the words are `TemplateWords`.

/// What the editor opens on: a new template (blank or a copy) or one of the person's own.
struct TemplateEditorRequest: Identifiable {
    let id = UUID()
    let mode: TemplateEditorViewModel.Mode

    static func new(startingFrom template: PromptTemplate? = nil) -> TemplateEditorRequest {
        TemplateEditorRequest(mode: .new(startingFrom: template))
    }

    /// Edit for the person's own; a built-in opens as a copy.
    static func edit(_ template: PromptTemplate) -> TemplateEditorRequest {
        TemplateEditorRequest(mode: template.isBuiltIn ? .new(startingFrom: template) : .edit(template))
    }
}

/// Name, kind, the clinical switch and the instructions; earlier versions for one of your own. Nothing is saved until
/// Save; Cancel asks before typed changes are lost; "Save and try…" saves, then the caller opens the run sheet.
struct TemplateEditorSheet: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @State private var model: TemplateEditorViewModel
    @State private var isConfirmingDiscard = false
    @State private var isSaving = false
    /// Runs the saved template once this sheet has gone.
    let onTry: (PromptTemplate) -> Void

    init(model: TemplateEditorViewModel, onTry: @escaping (PromptTemplate) -> Void) {
        _model = State(initialValue: model)
        self.onTry = onTry
    }

    var body: some View {
        NavigationStack {
            Form {
                if model.isNew { startSection }
                nameSection
                kindSection
                clinicalSection
                instructionsSection
                if !model.isNew, !model.versions.isEmpty { versionsSection }
                if let error = model.loadError ?? model.saveError {
                    Section {
                        Text(error)
                            .chirpFont(13)
                            .foregroundStyle(AppColor.error)
                    }
                    .listRowBackground(Tokens.Color.surface)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Tokens.Color.ground)
            .navigationTitle(model.isNew ? TemplateWords.newTitle : TemplateWords.editTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(TemplateWords.cancel) {
                        switch DiscardDecision.onCancel(hasInput: model.hasChanges) {
                        case .close: dismiss()
                        case .ask: isConfirmingDiscard = true
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(TemplateWords.save) { save(thenTry: false) }
                        .bold()
                        .disabled(!model.canSave || isSaving)
                }
            }
            .safeAreaInset(edge: .bottom) {
                ChirpBottomBar {
                    Button(TemplateWords.saveAndTry) { save(thenTry: true) }
                        .buttonStyle(.chirpPrimary)
                        .disabled(!model.canSave || isSaving)
                        .accessibilityHint(TemplateWords.saveAndTryHint)
                }
            }
        }
        .tint(AppColor.accentText)
        // Once: the task runs again when a pushed page (Earlier versions) pops, and must not reset typed fields.
        .task { if !model.isLoaded { await model.load() } }
        .discardInputConfirmation(
            TemplateWords.discardTitle, message: TemplateWords.discardMessage, hasInput: model.hasChanges,
            isAsking: $isConfirmingDiscard
        ) { dismiss() }
    }

    // MARK: - Sections

    private var startSection: some View {
        let points = environment.templateLibrary.startingPoints
        let selection = Binding<UUID?>(
            get: { model.startingPoint?.id },
            set: { id in
                let template = id.flatMap { id in points.first { $0.id == id } }
                Task { await model.start(from: template) }
            })
        return Section {
            Picker(TemplateWords.startFrom, selection: selection) {
                Text(TemplateWords.blank).tag(UUID?.none)
                Section(TemplateWords.documentsSection) {
                    ForEach(points.filter { $0.category == .deliverable }) { Text($0.name).tag(Optional($0.id)) }
                }
                Section(TemplateWords.rewritesSection) {
                    ForEach(points.filter { $0.category == .transform }) { Text($0.name).tag(Optional($0.id)) }
                }
            }
            .pickerStyle(.menu)
            .disabled(model.hasChanges)
            .frame(minHeight: 44)
        } footer: {
            Text(TemplateWords.startFromFooter)
        }
        .listRowBackground(Tokens.Color.surface)
        .task { if !environment.templateLibrary.hasLoaded { await environment.templateLibrary.load() } }
    }

    private var nameSection: some View {
        Section {
            ChirpTextField(TemplateWords.name, text: $model.name)
                .chirpFont(16)
                .textInputAutocapitalization(.words)
                .frame(minHeight: 44)
        } header: {
            Text(TemplateWords.name)
        } footer: {
            HStack(alignment: .firstTextBaseline) {
                if let problem = problemSentence(for: .name) {
                    Text(problem).foregroundStyle(AppColor.error)
                }
                Spacer(minLength: 8)
                Text(TemplateWords.nameCounter(model.draft.cleanedName.count)).monospacedDigit()
            }
        }
        .listRowBackground(Tokens.Color.surface)
    }

    private var kindSection: some View {
        Section {
            ChirpSegmentedControl(
                TemplateWords.makes, selection: $model.kind,
                segments: [
                    .init(TemplateWords.makesDocument, value: PromptTemplate.Category.deliverable),
                    .init(TemplateWords.makesRewrite, value: PromptTemplate.Category.transform),
                ], width: .fill)
        } header: {
            Text(TemplateWords.makes)
        } footer: {
            Text(TemplateWords.makesFooter)
        }
        .listRowBackground(Tokens.Color.surface)
    }

    private var clinicalSection: some View {
        Section {
            Toggle(TemplateWords.clinicalSwitch, isOn: $model.makesClinicalDocuments)
                .toggleStyle(.chirp)
                .chirpFont(15)
        } footer: {
            Text(TemplateWords.clinicalFooter)
        }
        .listRowBackground(Tokens.Color.surface)
    }

    private var instructionsSection: some View {
        Section {
            TextEditor(text: $model.instructions)
                .chirpFont(15)
                .frame(minHeight: 220)
                .overlay(alignment: .topLeading) {
                    if model.instructions.isEmpty {
                        ChirpPlaceholder(TemplateWords.instructionsPlaceholder)
                            .chirpFont(15)
                            .padding(.top, 8)
                            .padding(.leading, 5)
                    }
                }
                .accessibilityLabel(TemplateWords.instructions)
        } header: {
            Text(TemplateWords.instructions)
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                // Too long, or a reserved tag: said here, under the instructions, not under the name.
                if let problem = problemSentence(for: .instructions) {
                    Text(problem).foregroundStyle(AppColor.error)
                }
                Text(TemplateWords.instructionsHelp + " " + TemplateWords.instructionsCounter(model.characterCount))
                if model.instructions.contains("{{") {
                    Text(TemplateWords.placeholdersHelp)
                }
                if let note = model.versionNote {
                    Text(note).foregroundStyle(Tokens.Color.ink)
                }
            }
        }
        .listRowBackground(Tokens.Color.surface)
    }

    private var versionsSection: some View {
        let activeID = Self.activeVersionID(model.mode)
        return Section {
            NavigationLink {
                List {
                    ForEach(model.versions) { version in
                        NavigationLink {
                            TemplateVersionView(
                                name: model.name, version: version, isCurrent: version.id == activeID
                            ) {
                                model.useText(of: version)
                            }
                        } label: {
                            Text(TemplateWords.versionRow(version, isCurrent: version.id == activeID))
                                .chirpFont(15)
                                .frame(minHeight: 44, alignment: .leading)
                        }
                    }
                    .listRowBackground(Tokens.Color.surface)
                }
                .scrollContentBackground(.hidden)
                .background(Tokens.Color.ground)
                .navigationTitle(TemplateWords.earlierVersions(model.versions.count))
                .navigationBarTitleDisplayMode(.inline)
            } label: {
                Text(TemplateWords.earlierVersions(model.versions.count))
                    .chirpFont(15)
                    .frame(minHeight: 44, alignment: .leading)
            }
        }
        .listRowBackground(Tokens.Color.surface)
    }

    /// The problem's sentence when it belongs to `field` and something was typed (a fresh blank page asks nothing).
    private func problemSentence(for field: TemplateDraft.Problem.Field) -> String? {
        guard model.hasChanges, let problem = model.problem, problem.field == field else { return nil }
        return problem.sentence
    }

    private static func activeVersionID(_ mode: TemplateEditorViewModel.Mode) -> UUID? {
        if case .edit(let template) = mode { return template.activeVersionID }
        return nil
    }

    private func save(thenTry: Bool) {
        isSaving = true
        Task {
            defer { isSaving = false }
            guard let saved = await model.save() else { return }
            if thenTry { onTry(saved) }
            dismiss()
        }
    }
}

/// One earlier version's text, read only, with "Use this text" (it goes into the editor; history never changes).
private struct TemplateVersionView: View {
    @Environment(\.dismiss) private var dismiss
    let name: String
    let version: PromptVersion
    let isCurrent: Bool
    let use: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(TemplateWords.versionRow(version, isCurrent: isCurrent))
                    .chirpFont(13)
                    .foregroundStyle(Tokens.Color.secondary)
                Text(version.content)
                    .chirpFont(15)
                    .foregroundStyle(Tokens.Color.ink)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .chirpCard(radius: Tokens.Radius.m, padding: 14)
                Text(TemplateWords.useThisTextFooter)
                    .chirpFont(13)
                    .foregroundStyle(Tokens.Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
        }
        .background(Tokens.Color.ground)
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            ChirpBottomBar {
                Button(TemplateWords.useThisText) {
                    use()
                    dismiss()
                }
                .buttonStyle(.chirpSecondary)
            }
        }
    }
}

/// The read-only text of a built-in or of the version that made a document, with Copy.
struct TemplateInstructionsSheet: View {
    @Environment(\.dismiss) private var dismiss
    let subtitle: String
    let text: String
    @State private var copied = CopyFeedback()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(subtitle)
                        .chirpFont(13)
                        .foregroundStyle(Tokens.Color.secondary)
                    Text(text)
                        .chirpFont(15)
                        .foregroundStyle(Tokens.Color.ink)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .chirpCard(radius: Tokens.Radius.m, padding: 14)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
            }
            .background(Tokens.Color.ground)
            .navigationTitle(TemplateWords.instructionsTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        LocalPasteboard.copy(text)
                        copied.flash()
                    } label: {
                        Label(
                            copied.isShowing ? TemplateWords.copied : TemplateWords.copy,
                            systemImage: copied.isShowing ? "checkmark" : "doc.on.doc")
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .tint(AppColor.accentText)
    }
}

/// What the instructions sheet shows.
struct TemplateInstructions: Identifiable {
    let id = UUID()
    let subtitle: String
    let text: String
}

/// Opens the template editor for `request`, and after a "Save and try…" (once the editor has gone) the run sheet for
/// the saved template: the existing `TemplateLaunchSheet` (choose an item, model, notes), so the result is a normal
/// document with real provenance.
private struct TemplateEditorPresenter: ViewModifier {
    @Environment(AppEnvironment.self) private var environment
    @Binding var request: TemplateEditorRequest?
    @State private var pendingTry: PromptTemplate?
    @State private var trying: PromptTemplate?

    func body(content: Content) -> some View {
        content
            .sheet(
                item: $request,
                onDismiss: {
                    if let template = pendingTry {
                        pendingTry = nil
                        trying = template
                    }
                }
            ) { request in
                TemplateEditorSheet(model: environment.makeTemplateEditor(request.mode)) { pendingTry = $0 }
                    .environment(environment)
            }
            .sheet(item: $trying, onDismiss: { Task { await environment.deliverableLibrary.load() } }) { template in
                TemplateLaunchSheet(template: template, environment: environment)
                    .environment(environment)
            }
    }
}

extension View {
    /// The template editor for `request` (nil: closed), with "Save and try…" (plan 026).
    func templateEditor(_ request: Binding<TemplateEditorRequest?>) -> some View {
        modifier(TemplateEditorPresenter(request: request))
    }
}
