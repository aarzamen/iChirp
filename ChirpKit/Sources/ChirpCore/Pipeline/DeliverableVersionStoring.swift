import Foundation

/// Append-only versions of generated documents (plan 022 Step 4). `GRDBDeliverableStore` implements it next to
/// `DeliverableStoring`; the database itself refuses to change or delete a version.
public protocol DeliverableVersionStoring: Sendable {
    /// Every version of a document, oldest first (empty until its first versioned change).
    func fetchDeliverableVersions(deliverableID: UUID) async throws -> [DeliverableVersion]
    /// In one transaction: keeps the document's current text as a version first when it is not the latest one
    /// (`original` for the first, `handEdit` after the person edited it), appends `draft` as the next version, makes
    /// its text the document's text and raises (never lowers) the document's class to the draft's. nil when the document
    /// no longer exists (nothing is stored).
    func appendDeliverableVersion(_ draft: DeliverableVersionDraft, deliverableID: UUID) async throws
        -> DeliverableVersionAppend?
}
