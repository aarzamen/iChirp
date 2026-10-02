import ChirpCore
import Foundation

@testable import ChirpFeatures

/// Plan 026: the fake store keeps `GRDBDeliverableStore`'s template-library rules (TemplateLibraryStore.swift) on the
/// same rows, so the view-model tests exercise the real rules without a database. `failNextWrite` makes the next
/// write throw before it changes anything.
extension FakeDeliverableStore: TemplateLibraryStoring {
    func failNextWrite(with error: any Error) { pendingTemplateFailure = error }
    func failNextRead(with error: any Error) { pendingReadFailure = error }

    private func checkFailure() throws {
        if let failure = pendingTemplateFailure {
            pendingTemplateFailure = nil
            throw failure
        }
    }

    func fetchDeletedTemplates() async throws -> [PromptTemplate] {
        templates.values.filter { $0.deletedAt != nil }.sorted {
            ($0.deletedAt ?? .distantPast, $0.name) > ($1.deletedAt ?? .distantPast, $1.name)
        }
    }

    func createUserTemplate(_ draft: TemplateDraft) async throws -> PromptTemplate {
        try checkFailure()
        try check(draft, excluding: nil)
        let id = UUID()
        let version = PromptVersion(promptID: id, versionNumber: 1, content: draft.cleanedInstructions, origin: .user)
        versions[version.id] = version
        let template = PromptTemplate(
            id: id, name: draft.cleanedName, category: draft.category, outputPrivacyClass: draft.outputPrivacyClass,
            sortOrder: nextSortOrder(draft.category, excluding: nil), activeVersionID: version.id)
        templates[id] = template
        return template
    }

    func updateUserTemplate(id: UUID, with draft: TemplateDraft) async throws -> PromptTemplate {
        try checkFailure()
        var template = try live(id)
        guard !template.isBuiltIn else { throw TemplateLibraryError.builtInIsReadOnly }
        try check(draft, excluding: id)
        if versions[template.activeVersionID]?.content != draft.cleanedInstructions {
            let number = (versions.values.filter { $0.promptID == id }.map(\.versionNumber).max() ?? 0) + 1
            let version = PromptVersion(
                promptID: id, versionNumber: number, content: draft.cleanedInstructions, origin: .user)
            versions[version.id] = version
            template.activeVersionID = version.id
        }
        if template.category != draft.category {
            template.sortOrder = nextSortOrder(draft.category, excluding: id)
            template.category = draft.category
        }
        template.name = draft.cleanedName
        template.outputPrivacyClass = draft.outputPrivacyClass
        template.updatedAt = Date()
        templates[id] = template
        return template
    }

    func setTemplateVisible(id: UUID, isVisible: Bool) async throws {
        try checkFailure()
        _ = try live(id)
        templates[id]?.isVisible = isVisible
    }

    func reorderTemplates(category: PromptTemplate.Category, ids: [UUID]) async throws {
        try checkFailure()
        let section = templates.values.filter { $0.category == category && $0.deletedAt == nil }.map(\.id)
        guard ids.count == section.count, Set(ids).count == ids.count, Set(ids) == Set(section) else {
            throw TemplateLibraryError.invalidOrder
        }
        let base = category == .deliverable ? 0 : 1_000
        for (index, id) in ids.enumerated() { templates[id]?.sortOrder = base + index }
    }

    func deleteUserTemplate(id: UUID) async throws {
        try checkFailure()
        guard let template = templates[id] else { throw TemplateLibraryError.templateNotFound }
        guard !template.isBuiltIn else { throw TemplateLibraryError.builtInIsReadOnly }
        guard template.deletedAt == nil else { return }
        templateDeleteStamp += 1
        templates[id]?.deletedAt = Date(timeIntervalSinceReferenceDate: 800_000_000 + templateDeleteStamp)
    }

    func restoreDeletedTemplate(id: UUID) async throws -> PromptTemplate {
        try checkFailure()
        guard var template = templates[id] else { throw TemplateLibraryError.templateNotFound }
        guard template.deletedAt != nil else { return template }
        template.name = TemplateNaming.restoredName(of: template.name, taken: liveNames(excluding: id))
        template.sortOrder = nextSortOrder(template.category, excluding: id)
        template.deletedAt = nil
        templates[id] = template
        return template
    }

    func countDeliverables(promptID: UUID) async throws -> Int {
        if let failure = pendingReadFailure {
            pendingReadFailure = nil
            throw failure
        }
        return deliverables.values.filter { $0.promptID == promptID }.count
    }

    // MARK: Helpers

    private func live(_ id: UUID) throws -> PromptTemplate {
        guard let template = templates[id] else { throw TemplateLibraryError.templateNotFound }
        guard template.deletedAt == nil else { throw TemplateLibraryError.templateDeleted }
        return template
    }

    private func liveNames(excluding id: UUID?) -> [String] {
        templates.values.filter { $0.deletedAt == nil && $0.id != id }.map(\.name)
    }

    private func check(_ draft: TemplateDraft, excluding id: UUID?) throws {
        if let problem = draft.problem(takenNames: liveNames(excluding: id)) {
            throw TemplateLibraryError.problem(problem)
        }
    }

    private func nextSortOrder(_ category: PromptTemplate.Category, excluding id: UUID?) -> Int {
        let orders = templates.values.filter { $0.category == category && $0.deletedAt == nil && $0.id != id }
            .map(\.sortOrder)
        return orders.max().map { $0 + 1 } ?? (category == .deliverable ? 0 : 1_000)
    }
}
