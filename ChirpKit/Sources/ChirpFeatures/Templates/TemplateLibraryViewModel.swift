// Semantics from MacParakeet (GPL-3.0): Sources/MacParakeetViewModels/QuickPromptsViewModel.swift @ bbae9e0e —
// hide/show and reorder per bucket (built-ins hide-only); and Sources/MacParakeetViewModels/PromptsViewModel.swift
// @ bbae9e0e — delete and restore deleted prompts. Fresh implementation, not a line port.

import ChirpCore
import Foundation
import Observation

/// What a template row offers (the ⋯ menu). Built-ins can be duplicated, hidden and moved; templates of the person's
/// own can also be edited and deleted.
public enum TemplateAction: Sendable, Equatable, CaseIterable {
    case duplicateAndEdit, edit, duplicate, hide, show, moveUp, moveDown, viewInstructions, delete
}

/// The question before a delete: what stays, and which recipes stop.
public struct TemplateDeleteImpact: Sendable, Equatable {
    public var title: String
    public var message: String
}

/// The Templates screen (plan 026): the Documents and Rewrites sections in the person's order, hidden ones marked,
/// deleted ones with Restore. Every change is saved at once, then the lists are read again and `didChange` tells the
/// Transforms tab. A store error is one sentence (`actionError`) and changes nothing on screen.
@MainActor @Observable public final class TemplateLibraryViewModel {
    /// Documents (`.deliverable`), in order, hidden ones included.
    public private(set) var documents: [PromptTemplate] = []
    /// Rewrites (`.transform`), in order, hidden ones included.
    public private(set) var rewrites: [PromptTemplate] = []
    /// Deleted templates, newest delete first (only the person's own can be deleted from this screen).
    public private(set) var deleted: [PromptTemplate] = []
    public private(set) var loadError: String?
    public private(set) var actionError: String?
    /// A note after a change that did something the person might not expect (a restored template renamed).
    public private(set) var notice: String?
    public private(set) var hasLoaded = false

    @ObservationIgnored private let store: any DeliverableStoring & TemplateLibraryStoring
    @ObservationIgnored private let recipesUsing: @MainActor (UUID) -> [String]
    @ObservationIgnored private let didChange: @MainActor () async -> Void

    /// - Parameters:
    ///   - recipesUsing: the names of the recipes that make a Document with a template (`CreateRecipe.uses`).
    ///   - didChange: after every saved change (the app reloads the Transforms tab's lists).
    public init(
        store: any DeliverableStoring & TemplateLibraryStoring,
        recipesUsing: @escaping @MainActor (UUID) -> [String],
        didChange: @escaping @MainActor () async -> Void
    ) {
        self.store = store
        self.recipesUsing = recipesUsing
        self.didChange = didChange
    }

    public func templates(in category: PromptTemplate.Category) -> [PromptTemplate] {
        category == .deliverable ? documents : rewrites
    }

    /// Hidden templates that are not deleted.
    public var hiddenCount: Int { (documents + rewrites).filter { !$0.isVisible }.count }

    /// Any template of the person's own that is not deleted (else the screen shows the "Make a template your way"
    /// card).
    public var hasTemplatesOfYourOwn: Bool { (documents + rewrites).contains { !$0.isBuiltIn } }

    /// What the editor's "Start from" offers after Blank: every template that is not deleted, Documents first.
    public var startingPoints: [PromptTemplate] { documents + rewrites }

    public func load() async {
        do {
            let all = try await store.fetchTemplates()
            let gone = try await store.fetchDeletedTemplates()
            documents = all.filter { $0.category == .deliverable }
            rewrites = all.filter { $0.category == .transform }
            deleted = gone
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
        hasLoaded = true
    }

    // MARK: - Row actions

    public func actions(for template: PromptTemplate) -> [TemplateAction] {
        let visibility: TemplateAction = template.isVisible ? .hide : .show
        if template.isBuiltIn {
            return [.duplicateAndEdit, visibility, .moveUp, .moveDown, .viewInstructions]
        }
        return [.edit, .duplicate, visibility, .moveUp, .moveDown, .delete]
    }

    public func setVisible(_ template: PromptTemplate, _ isVisible: Bool) async {
        await change { try await self.store.setTemplateVisible(id: template.id, isVisible: isVisible) }
    }

    public func canMoveUp(_ template: PromptTemplate) -> Bool {
        guard let index = position(of: template) else { return false }
        return index > 0
    }

    public func canMoveDown(_ template: PromptTemplate) -> Bool {
        guard let index = position(of: template) else { return false }
        return index < templates(in: template.category).count - 1
    }

    public func moveUp(_ template: PromptTemplate) async {
        guard canMoveUp(template), let index = position(of: template) else { return }
        await move(fromOffsets: IndexSet(integer: index), toOffset: index - 1, in: template.category)
    }

    public func moveDown(_ template: PromptTemplate) async {
        guard canMoveDown(template), let index = position(of: template) else { return }
        await move(fromOffsets: IndexSet(integer: index), toOffset: index + 2, in: template.category)
    }

    /// A drag in one section (SwiftUI `onMove` offsets): saves the section's whole new order.
    public func move(fromOffsets source: IndexSet, toOffset destination: Int, in category: PromptTemplate.Category)
        async
    {
        let current = templates(in: category).map(\.id)
        let ids = Self.moved(current, fromOffsets: source, toOffset: destination)
        guard ids != current else { return }
        await reorder(ids, in: category)
    }

    /// Saves a section's full order (every template of that section that is not deleted, once).
    public func reorder(_ ids: [UUID], in category: PromptTemplate.Category) async {
        await change { try await self.store.reorderTemplates(category: category, ids: ids) }
    }

    // MARK: - Delete and restore

    /// The delete question: the documents made with it stay, the recipes that make it stop until it is restored.
    public func deleteImpact(of template: PromptTemplate) async -> TemplateDeleteImpact {
        // A count that cannot be read must not claim there are none: say they stay, without a number.
        let documents = try? await store.countDeliverables(promptID: template.id)
        let recipes = recipesUsing(template.id)
        var sentences: [String] = []
        switch documents {
        case nil: sentences.append("Documents made with it stay.")
        case 0?: break
        case 1?: sentences.append("The document made with it stays and still says which template made it.")
        case let count?:
            sentences.append("The \(count) documents made with it stay and still say which template made it.")
        }
        switch recipes.count {
        case 0: break
        case 1: sentences.append("The recipe “\(recipes[0])” stops working until you restore the template.")
        default:
            sentences.append(
                "The recipes \(Self.list(recipes.map { "“\($0)”" })) stop working until you restore the template.")
        }
        sentences.append("You can restore it later from Deleted templates.")
        return TemplateDeleteImpact(title: "Delete “\(template.name)”?", message: sentences.joined(separator: " "))
    }

    /// Soft delete after the person confirmed. Versions and documents stay.
    public func delete(_ template: PromptTemplate) async {
        await change { try await self.store.deleteUserTemplate(id: template.id) }
    }

    public func restore(_ template: PromptTemplate) async {
        let restored = await change { try await self.store.restoreDeletedTemplate(id: template.id) }
        if let restored, restored.name != template.name {
            notice = "Restored as “\(restored.name)”: another template has its name."
        }
    }

    public func dismissActionError() { actionError = nil }
    public func dismissNotice() { notice = nil }

    // MARK: - Helpers

    private func position(of template: PromptTemplate) -> Int? {
        templates(in: template.category).firstIndex { $0.id == template.id }
    }

    /// Runs one write; on success reads the lists again and tells the Transforms tab, on failure says why and keeps
    /// the lists as they were.
    @discardableResult
    private func change<Result>(_ write: () async throws -> Result) async -> Result? {
        notice = nil
        let result: Result
        do {
            result = try await write()
            actionError = nil
        } catch {
            actionError = error.localizedDescription
            // A refused order means this screen's list is out of date (another screen changed the section): read it
            // again so the next move starts from what is stored.
            if (error as? TemplateLibraryError) == .invalidOrder { await load() }
            return nil
        }
        await load()
        await didChange()
        return result
    }

    /// `ids` with the items at `source` moved to `destination` (SwiftUI `onMove` semantics: `destination` is an index
    /// in the list before the move).
    static func moved(_ ids: [UUID], fromOffsets source: IndexSet, toOffset destination: Int) -> [UUID] {
        let valid = source.filter { $0 >= 0 && $0 < ids.count }
        let moving = valid.map { ids[$0] }
        var remaining = ids
        for index in valid.sorted(by: >) { remaining.remove(at: index) }
        let target = min(max(0, destination - valid.filter { $0 < destination }.count), remaining.count)
        remaining.insert(contentsOf: moving, at: target)
        return remaining
    }

    /// "“A”", "“A” and “B”", "“A”, “B” and “C”".
    static func list(_ items: [String]) -> String {
        guard items.count > 1 else { return items.first ?? "" }
        return items.dropLast().joined(separator: ", ") + " and " + (items.last ?? "")
    }
}
