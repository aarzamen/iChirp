import ChirpCore
import ChirpFeatures
import ChirpUI
import SwiftUI

// Plan 026 Step 7: the person's templates. Reached from Transforms ("Templates · Edit") and Settings → Text →
// Templates; mirrors the Recipes sheet (`CreateRecipeViews.swift`). Logic: `TemplateLibraryViewModel`.

/// Documents and Rewrites in the person's order (hidden ones marked), Reorder / Finish, a ⋯ menu per row (built-ins:
/// Duplicate and edit, Hide/Show, Move, View instructions; yours: Edit, Duplicate, Hide/Show, Move, Delete…), swipe
/// Hide and Delete, and "Deleted templates" with Restore.
struct TemplatesScreen: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var editMode: EditMode = .inactive
    @State private var editing: TemplateEditorRequest?
    @State private var deleting: (template: PromptTemplate, impact: TemplateDeleteImpact)?
    @State private var instructions: TemplateInstructions?

    var body: some View {
        let library = environment.templateLibrary
        List {
            if library.hasLoaded, !library.hasTemplatesOfYourOwn {
                Section { emptyCard }
                    .listRowBackground(Tokens.Color.surface)
            }
            if let error = library.loadError {
                Section {
                    Text("Couldn’t read the templates: \(error)")
                        .chirpFont(13)
                        .foregroundStyle(AppColor.error)
                }
                .listRowBackground(Tokens.Color.surface)
            }
            if let notice = library.notice {
                Section {
                    Text(notice)
                        .chirpFont(14)
                        .foregroundStyle(Tokens.Color.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .listRowBackground(Tokens.Color.surface)
            }
            section(.deliverable, library.documents)
            section(.transform, library.rewrites)
            Section {
                Button {
                    editing = .new()
                } label: {
                    Label(TemplateWords.newTemplate, systemImage: "plus")
                        .chirpFont(15.5, .semibold)
                        .frame(minHeight: 44)
                }
                .disabled(editMode.isEditing)
            } footer: {
                Text(TemplateWords.screenFooter)
            }
            .listRowBackground(Tokens.Color.surface)
            if !library.deleted.isEmpty {
                Section {
                    ForEach(library.deleted) { template in
                        deletedRow(template)
                    }
                } header: {
                    Text(TemplateWords.deletedSection)
                } footer: {
                    Text(TemplateWords.deletedFooter)
                }
                .listRowBackground(Tokens.Color.surface)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Tokens.Color.ground)
        .environment(\.editMode, $editMode)
        .navigationTitle(TemplateWords.screenTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(editMode.isEditing ? TemplateWords.finish : TemplateWords.reorder) {
                    withAnimation { editMode = editMode.isEditing ? .inactive : .active }
                }
            }
        }
        .tint(AppColor.accentText)
        .task { await library.load() }
        .refreshable { await library.load() }
        .templateEditor($editing)
        .sheet(item: $instructions) { shown in
            TemplateInstructionsSheet(subtitle: shown.subtitle, text: shown.text)
        }
        .confirmationDialog(
            deleting?.impact.title ?? "",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible,
            presenting: deleting
        ) { pending in
            Button(TemplateWords.deleteConfirm, role: .destructive) {
                Task { await library.delete(pending.template) }
            }
            Button(TemplateWords.keep, role: .cancel) {}
        } message: { pending in
            Text(pending.impact.message)
        }
        .alert(
            "Couldn’t change the templates",
            isPresented: Binding(get: { library.actionError != nil }, set: { if !$0 { library.dismissActionError() } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(library.actionError ?? "")
        }
    }

    private var emptyCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(TemplateWords.emptyCardTitle)
                .chirpFont(16, .semibold)
                .foregroundStyle(Tokens.Color.ink)
                .accessibilityAddTraits(.isHeader)
            Text(TemplateWords.emptyCardMessage)
                .chirpFont(14)
                .foregroundStyle(Tokens.Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(TemplateWords.newTemplate) { editing = .new() }
                .buttonStyle(.chirp(.filled, size: .compact))
                .fixedSize()
                .padding(.top, 4)
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder private func section(_ category: PromptTemplate.Category, _ templates: [PromptTemplate]) -> some View {
        if !templates.isEmpty {
            Section {
                ForEach(templates) { template in
                    row(template)
                }
                .onMove { offsets, destination in
                    Task {
                        await environment.templateLibrary.move(
                            fromOffsets: offsets, toOffset: destination, in: category)
                    }
                }
            } header: {
                Text(TemplateWords.sectionTitle(category))
            }
            .listRowBackground(Tokens.Color.surface)
        }
    }

    private func row(_ template: PromptTemplate) -> some View {
        let library = environment.templateLibrary
        return HStack(spacing: 10) {
            TemplateLibraryRowContent(template: template)
                .contentShape(Rectangle())
                .onTapGesture {
                    if !editMode.isEditing { perform(template.isBuiltIn ? .viewInstructions : .edit, template) }
                }
                .accessibilityAddTraits(.isButton)
                .accessibilityHint(template.isBuiltIn ? "Shows its instructions" : "Opens it in the editor")
            if !editMode.isEditing {
                Menu {
                    ForEach(library.actions(for: template), id: \.self) { action in
                        Button(
                            TemplateWords.actionTitle(action), systemImage: TemplateWords.actionImage(action),
                            role: action == .delete ? .destructive : nil
                        ) { perform(action, template) }
                        .disabled(
                            (action == .moveUp && !library.canMoveUp(template))
                                || (action == .moveDown && !library.canMoveDown(template)))
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .chirpGlyph(20, .regular, relativeTo: .body)
                        .foregroundStyle(AppColor.accentText)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(TemplateWords.menuLabel(template))
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if !template.isBuiltIn {
                Button(TemplateWords.actionTitle(.delete), role: .destructive) { perform(.delete, template) }
            }
            Button(TemplateWords.actionTitle(template.isVisible ? .hide : .show)) {
                perform(template.isVisible ? .hide : .show, template)
            }
            .tint(Tokens.Color.secondary)
        }
    }

    private func deletedRow(_ template: PromptTemplate) -> some View {
        HStack(spacing: 10) {
            TemplateLibraryRowContent(template: template)
            Button(TemplateWords.restore) {
                Task { await environment.templateLibrary.restore(template) }
            }
            .buttonStyle(.chirp(.tinted, size: .compact))
            .fixedSize()
            .accessibilityLabel("\(TemplateWords.restore) \(template.name)")
        }
    }

    private func perform(_ action: TemplateAction, _ template: PromptTemplate) {
        let library = environment.templateLibrary
        switch action {
        case .duplicateAndEdit, .duplicate: editing = .new(startingFrom: template)
        case .edit: editing = .edit(template)
        case .hide: Task { await library.setVisible(template, false) }
        case .show: Task { await library.setVisible(template, true) }
        case .moveUp: Task { await library.moveUp(template) }
        case .moveDown: Task { await library.moveDown(template) }
        case .viewInstructions:
            Task {
                let text = (try? await environment.deliverableStore.fetchVersion(id: template.activeVersionID))?.content
                instructions = TemplateInstructions(
                    subtitle: template.name, text: text ?? "The instructions could not be read.")
            }
        case .delete:
            Task { deleting = (template, await library.deleteImpact(of: template)) }
        }
    }
}

/// A template in the Templates list: icon, name, built-in line or "Your template", Clinical and Hidden badges.
struct TemplateLibraryRowContent: View {
    let template: PromptTemplate

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(AppColor.tintFill)
                Image(systemName: TemplateStyle.of(template).systemImage)
                    .chirpGlyph(15, .semibold, relativeTo: .body)
                    .foregroundStyle(template.isVisible ? Tokens.Color.accentInk : Tokens.Color.mutedText)
            }
            .chirpScaledFrame(width: 34, height: 34, relativeTo: .body)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(template.name)
                    .chirpFont(15.5, .semibold)
                    .foregroundStyle(Tokens.Color.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text(TemplateWords.rowSubtitle(template))
                    .chirpFont(12.5)
                    .foregroundStyle(Tokens.Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if template.outputPrivacyClass == .clinical || !template.isVisible {
                    HStack(spacing: 6) {
                        if template.outputPrivacyClass == .clinical {
                            PrivacyClassBadge(privacyClass: .clinical)
                        }
                        if !template.isVisible { HiddenBadge() }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: 44)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(TemplateWords.spokenRow(template))
    }
}

/// The "Hidden" capsule on a template row.
struct HiddenBadge: View {
    var body: some View {
        Label(TemplateWords.hiddenCaption, systemImage: "eye.slash")
            .labelStyle(.titleAndIcon)
            .chirpFont(11.5, .semibold)
            .foregroundStyle(Tokens.Color.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(AppColor.quietFill))
    }
}
