// Semantics from MacParakeet (GPL-3.0): Sources/MacParakeetViewModels/PromptsViewModel.swift @ bbae9e0e — addPrompt
// and edit (name and content required, unique names), version history and "use an earlier version's text". Fresh
// implementation, not a line port: built-ins open only as a copy (plan 026 D3), and a version's text goes into the
// draft, never back into history.

import ChirpCore
import Foundation
import Observation

/// The template editor (plan 026): a new template (blank, or starting from any template) or one of the person's own.
/// Problems are sentences while typing; Save makes the template, or saves the row and a new version only when the
/// instructions changed. Nothing is saved until Save.
@MainActor @Observable public final class TemplateEditorViewModel {
    public enum Mode: Sendable, Equatable {
        /// A new template; `startingFrom` fills it (nil is a blank page).
        case new(startingFrom: PromptTemplate?)
        /// One of the person's own. A built-in passed here opens as `.new(startingFrom:)` (built-ins are read-only).
        case edit(PromptTemplate)
    }

    public private(set) var mode: Mode
    public var name = ""
    public var kind: PromptTemplate.Category = .deliverable
    public var instructions = ""
    public var makesClinicalDocuments = false
    /// Earlier versions of the template being edited, newest first (empty for a new one).
    public private(set) var versions: [PromptVersion] = []
    public private(set) var loadError: String?
    public private(set) var saveError: String?
    public private(set) var isLoaded = false

    @ObservationIgnored private let store: any DeliverableStoring & TemplateLibraryStoring
    @ObservationIgnored private let didSave: @MainActor (PromptTemplate) async -> Void
    /// The names of the other templates that are not deleted (for "already a template").
    @ObservationIgnored private var takenNames: [String] = []
    /// What the fields held after loading or saving, for `hasChanges`.
    @ObservationIgnored private var baseline: TemplateDraft?
    /// The active version's text of the template being edited.
    @ObservationIgnored private var savedInstructions: String?

    public init(
        mode: Mode,
        store: any DeliverableStoring & TemplateLibraryStoring,
        didSave: @escaping @MainActor (PromptTemplate) async -> Void = { _ in }
    ) {
        if case .edit(let template) = mode, template.isBuiltIn {
            self.mode = .new(startingFrom: template)
        } else {
            self.mode = mode
        }
        self.store = store
        self.didSave = didSave
    }

    public var isNew: Bool {
        if case .new = mode { return true }
        return false
    }

    /// The template a new one starts from (nil: Blank, or editing).
    public var startingPoint: PromptTemplate? {
        if case .new(let template) = mode { return template }
        return nil
    }

    public var draft: TemplateDraft {
        TemplateDraft(
            name: name, category: kind, instructions: instructions, makesClinicalDocuments: makesClinicalDocuments)
    }

    public var problem: TemplateDraft.Problem? { draft.problem(takenNames: takenNames) }
    public var problemSentence: String? { problem?.sentence }
    public var canSave: Bool { isLoaded && problem == nil }
    /// Characters of the instructions as they will be saved ("1,240 of 4,000 characters").
    public var characterCount: Int { draft.characterCount }

    /// The fields differ from what was loaded or last saved (Cancel then asks "Discard your changes?").
    public var hasChanges: Bool {
        guard let baseline else { return false }
        return draft.cleanedName != baseline.cleanedName || kind != baseline.category
            || draft.cleanedInstructions != baseline.cleanedInstructions
            || makesClinicalDocuments != baseline.makesClinicalDocuments
    }

    /// The version Save would make when editing and the instructions changed; nil otherwise.
    public var nextVersionNumber: Int? {
        guard case .edit = mode, let savedInstructions, draft.cleanedInstructions != savedInstructions else {
            return nil
        }
        return (versions.map(\.versionNumber).max() ?? 0) + 1
    }

    /// "Saving makes version 3. Documents made before keep the version they used." when Save would make one.
    public var versionNote: String? {
        nextVersionNumber.map {
            "Saving makes version \($0). Documents made before keep the version they used."
        }
    }

    public func load() async {
        do {
            try await refresh()
            loadError = nil
            isLoaded = true
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// New only: fills the fields from `template` (a copy's name, its kind, text and clinical switch) or a blank page.
    public func start(from template: PromptTemplate?) async {
        guard isNew else { return }
        mode = .new(startingFrom: template)
        await load()
    }

    /// Loads an earlier version's text into the draft. History never changes; Save makes a new version.
    public func useText(of version: PromptVersion) {
        instructions = version.content
    }

    /// Saves the draft. Returns the saved template, or nil with `saveError` set (nothing changed in the store).
    public func save() async -> PromptTemplate? {
        if let problem {
            saveError = problem.sentence
            return nil
        }
        do {
            let saved: PromptTemplate
            switch mode {
            case .new:
                saved = try await store.createUserTemplate(draft)
            case .edit(let template):
                saved = try await store.updateUserTemplate(id: template.id, with: draft)
            }
            saveError = nil
            mode = .edit(saved)
            try await refresh()
            await didSave(saved)
            return saved
        } catch {
            saveError = error.localizedDescription
            return nil
        }
    }

    public func dismissSaveError() { saveError = nil }

    // MARK: - Helpers

    /// Reads the names, and for an edit the versions; fills the fields from the mode and records the baseline.
    private func refresh() async throws {
        let others = try await store.fetchTemplates()
        switch mode {
        case .new(let template):
            takenNames = others.map(\.name)
            versions = []
            savedInstructions = nil
            if let template {
                let text = try await store.fetchVersion(id: template.activeVersionID)?.content ?? ""
                var copy = TemplateDraft(template: template, instructions: text)
                copy.name = TemplateNaming.copyName(of: template.name, taken: takenNames)
                fill(copy)
            } else {
                fill(
                    TemplateDraft(name: "", category: .deliverable, instructions: "", makesClinicalDocuments: false))
            }
        case .edit(let template):
            takenNames = others.filter { $0.id != template.id }.map(\.name)
            let current = try await store.fetchTemplate(id: template.id) ?? template
            mode = .edit(current)
            versions = try await store.fetchVersions(promptID: current.id).reversed()
            let text = versions.first { $0.id == current.activeVersionID }?.content ?? ""
            savedInstructions = text
            fill(TemplateDraft(template: current, instructions: text))
        }
    }

    private func fill(_ draft: TemplateDraft) {
        name = draft.name
        kind = draft.category
        instructions = draft.instructions
        makesClinicalDocuments = draft.makesClinicalDocuments
        baseline = draft
    }
}
