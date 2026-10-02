// Fresh implementation for iChirp (plan 026): what made a document, and what happened to that template since. The
// facts come from the document's title snapshot, its immutable template version, and the template row as it is now
// (deleted rows included), so a document keeps saying what made it after an edit, a rename or a delete.

import ChirpCore
import Foundation

/// The Details lines about a document's template: "Clinic SOAP · version 2", and when something changed since, what
/// ("Now called “SOAP (clinic)”.", "Edited since: now version 3.", "Deleted. Restore it in Templates to use it again.").
public struct DocumentTemplateProvenance: Sendable, Equatable {
    /// The template's name when the document was made (`Deliverable.title`) and the version that made it.
    public var made: String
    /// What changed since, in order; empty when nothing did.
    public var changes: [String]
    /// The template was deleted (it can be restored in Templates).
    public var isTemplateDeleted: Bool
    /// The exact instructions that made the document can be shown (its version is known).
    public var canShowInstructions: Bool

    /// The "Template now" row: nil when nothing changed.
    public var now: String? { changes.isEmpty ? nil : changes.joined(separator: " ") }

    /// nil for a document no template made (an Ask answer).
    /// - Parameters:
    ///   - template: the template row as it is now, deleted or not (`DeliverableStoring.fetchTemplate(id:)`).
    ///   - versionUsed: the document's version (`promptVersionID`).
    ///   - activeVersion: the template's active version now.
    public static func of(
        document: Deliverable,
        template: PromptTemplate?,
        versionUsed: PromptVersion?,
        activeVersion: PromptVersion?
    ) -> DocumentTemplateProvenance? {
        guard let promptID = document.promptID else { return nil }
        let made = versionUsed.map { "\(document.title) · version \($0.versionNumber)" } ?? document.title
        var changes: [String] = []
        var isDeleted = false
        if let template, template.id == promptID {
            if template.deletedAt != nil {
                isDeleted = true
                changes.append("Deleted. Restore it in Templates to use it again.")
            } else {
                if template.name != document.title { changes.append("Now called “\(template.name)”.") }
                if let activeVersion, let versionUsed, activeVersion.id != versionUsed.id {
                    changes.append(
                        activeVersion.origin == .systemUpdate
                            ? "Updated by the app since: now version \(activeVersion.versionNumber)."
                            : "Edited since: now version \(activeVersion.versionNumber).")
                }
            }
        } else {
            changes.append("This template no longer exists.")
        }
        return DocumentTemplateProvenance(
            made: made, changes: changes, isTemplateDeleted: isDeleted, canShowInstructions: versionUsed != nil)
    }
}
