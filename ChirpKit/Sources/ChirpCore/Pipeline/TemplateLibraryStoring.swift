import Foundation

/// The person's own templates (plan 026): create, edit as immutable versions, hide, reorder, soft delete and restore.
/// `GRDBDeliverableStore` implements it next to `DeliverableStoring`; every write is one transaction that re-checks the
/// draft (`TemplateDraft.problem`) and name uniqueness inside it. Built-ins can be hidden and moved, never edited,
/// renamed or deleted here. Contract: spec/contracts/deliverables-v1.md "Template library".
public protocol TemplateLibraryStoring: Sendable {
    /// Soft-deleted templates, newest delete first. Only the person's own can be deleted here; a built-in appears only
    /// if the older `softDeleteTemplate` deleted it (no screen calls that), and then it can be restored too.
    func fetchDeletedTemplates() async throws -> [PromptTemplate]
    /// A new template of the person's own with version 1 (origin `user`), shown, last in its section.
    func createUserTemplate(_ draft: TemplateDraft) async throws -> PromptTemplate
    /// Saves name, kind and the clinical switch on the row; appends a version (and makes it active) only when the
    /// instructions changed. Built-ins are refused (`builtInIsReadOnly`), deleted ones too (`templateDeleted`).
    func updateUserTemplate(id: UUID, with draft: TemplateDraft) async throws -> PromptTemplate
    /// Hide or show any template that is not deleted, built-ins too. Never marks a built-in customized.
    func setTemplateVisible(id: UUID, isVisible: Bool) async throws
    /// `ids` must be every template of that section that is not deleted, each once (`invalidOrder` otherwise, and
    /// nothing changes). Never marks a built-in customized.
    func reorderTemplates(category: PromptTemplate.Category, ids: [UUID]) async throws
    /// Soft delete of the person's own template; its versions and the documents made with it stay. Built-ins refused.
    func deleteUserTemplate(id: UUID) async throws
    /// Brings a deleted template back, last in its section; a name taken meanwhile becomes "<name> (restored)".
    func restoreDeletedTemplate(id: UUID) async throws -> PromptTemplate
    /// Documents that name this template (any version), for the delete question.
    func countDeliverables(promptID: UUID) async throws -> Int
}

public enum TemplateLibraryError: Error, Equatable, LocalizedError {
    case builtInIsReadOnly
    case templateNotFound
    case templateDeleted
    case invalidOrder
    case problem(TemplateDraft.Problem)

    public var errorDescription: String? {
        switch self {
        case .builtInIsReadOnly: "Built-in templates can’t be changed. Duplicate it to make your own."
        case .templateNotFound: "This template no longer exists."
        case .templateDeleted: "This template was deleted. Restore it first."
        case .invalidOrder: "The order could not be saved. Nothing changed."
        case .problem(let problem): problem.sentence
        }
    }
}
