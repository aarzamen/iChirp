import Foundation

/// Persistence for templates, their immutable versions, generated deliverables and the metadata-only run ledger. The
/// GRDB implementation lives in ChirpStore (`GRDBDeliverableStore`). Contract: spec/contracts/deliverables-v1.md.
public protocol DeliverableStoring: Sendable {
    // MARK: Templates

    /// Inserts missing built-ins (with version 1) and, for a built-in the user has not customized, appends a
    /// `systemUpdate` version when the definition's `revision` is newer. Never touches user templates or edits.
    func installBuiltInTemplates(_ templates: [BuiltInPromptTemplate]) async throws
    /// Templates not soft-deleted, ordered by `sortOrder` then name.
    func fetchTemplates() async throws -> [PromptTemplate]
    func fetchTemplate(id: UUID) async throws -> PromptTemplate?
    func fetchVersion(id: UUID) async throws -> PromptVersion?
    /// Every version of a template, oldest first.
    func fetchVersions(promptID: UUID) async throws -> [PromptVersion]
    /// A new user template with version 1.
    func createTemplate(
        name: String,
        category: PromptTemplate.Category,
        content: String,
        outputPrivacyClass: PrivacyClass?
    ) async throws -> PromptTemplate
    /// Appends an immutable user version and makes it active (a built-in becomes customized). Returns the new version.
    func addVersion(promptID: UUID, content: String) async throws -> PromptVersion
    /// Soft delete: hides the template; its versions and the deliverables that used them stay.
    func softDeleteTemplate(id: UUID) async throws

    // MARK: Deliverables

    func insertDeliverable(_ deliverable: Deliverable) async throws
    func fetchDeliverable(id: UUID) async throws -> Deliverable?
    /// Newest first.
    func fetchDeliverables(transcriptionID: UUID) async throws -> [Deliverable]
    /// Newest first, across all transcripts.
    func fetchRecentDeliverables(limit: Int) async throws -> [Deliverable]
    /// Atomically replaces only the text (the user's edit) and stamps `editedAt` / `updatedAt`. nil when gone.
    func updateDeliverableText(id: UUID, text: String) async throws -> Deliverable?
    /// Raises every deliverable of a transcript to at least `privacyClass` (never lowers one). Returns rows changed.
    func raiseDeliverablePrivacyClass(transcriptionID: UUID, to privacyClass: PrivacyClass) async throws -> Int
    func deleteDeliverable(id: UUID) async throws

    // MARK: Run ledger

    func recordRun(_ run: LanguageModelRun) async throws
    /// Newest first.
    func fetchRuns(limit: Int) async throws -> [LanguageModelRun]
}
