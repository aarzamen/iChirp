// Fresh implementation for iChirp (M4 UI lane): the Transforms tab's lists and one generated document. Reads and
// edits through `DeliverableStoring` (contract spec/contracts/deliverables-v1.md); never touches a transcript.

import ChirpCore
import Foundation
import Observation

/// The Transforms tab: the templates and the generated documents, newest first, a page at a time. "Show more" reaches
/// every document there is (UX audit F43: nothing may become unreachable past the first page).
@MainActor @Observable public final class DeliverableLibraryViewModel {
    public private(set) var templates: [PromptTemplate] = []
    /// The documents shown: the newest `recentLimit`, plus a page for every `showMore()`.
    public private(set) var recent: [Deliverable] = []
    /// There are older documents than the ones in `recent`.
    public private(set) var hasMore = false
    /// Set when the lists could not be read.
    public private(set) var loadError: String?
    /// False until the first `load()` finished.
    public private(set) var hasLoaded = false

    @ObservationIgnored private let store: any DeliverableStoring
    /// How many documents a page adds.
    public let pageSize: Int
    /// How many documents `load()` reads: grows by `pageSize` with each `showMore()` and stays for later reloads.
    @ObservationIgnored private var limit: Int

    public init(store: any DeliverableStoring, recentLimit: Int = 50) {
        self.store = store
        pageSize = max(1, recentLimit)
        limit = max(1, recentLimit)
    }

    /// Documents made from a whole transcript (Summary, Meeting notes, SOAP note, …).
    public var documentTemplates: [PromptTemplate] { templates.filter { $0.category == .deliverable } }
    /// Rewrites (Polish, Distill, Decide, Brief).
    public var transformTemplates: [PromptTemplate] { templates.filter { $0.category == .transform } }

    // Plan 026: hidden templates stay in `templates` (and the two lists above) because recipes, Create's validation,
    // Jev's suggestion and the SOAP hand-off look templates up there; only pickers use the shown lists below. Do not
    // "simplify" `documentTemplates` into the shown list.

    /// Documents a picker shows (hidden ones left out).
    public var visibleDocumentTemplates: [PromptTemplate] { documentTemplates.filter(\.isVisible) }
    /// Rewrites a picker shows (hidden ones left out).
    public var visibleRewriteTemplates: [PromptTemplate] { transformTemplates.filter(\.isVisible) }
    /// Hidden templates that are not deleted ("2 hidden").
    public var hiddenTemplateCount: Int { templates.filter { !$0.isVisible }.count }

    /// A picker's list for one section: the shown templates, plus `keeping` in its place when it is a hidden template
    /// of that section (a choice already made, e.g. Create's remembered template, stays choosable).
    public func pickerTemplates(_ category: PromptTemplate.Category, keeping kept: UUID?) -> [PromptTemplate] {
        templates.filter { $0.category == category && ($0.isVisible || $0.id == kept) }
    }

    public func load() async {
        do {
            templates = try await store.fetchTemplates()
            // One more than shown says whether an older document exists.
            let fetched = try await store.fetchRecentDeliverables(limit: limit + 1)
            recent = Array(fetched.prefix(limit))
            hasMore = fetched.count > limit
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
        hasLoaded = true
    }

    /// Reads the next page of older documents (the list keeps them on later reloads).
    public func showMore() async {
        guard hasMore else { return }
        limit += pageSize
        await load()
    }
}

/// One generated document: its text (editable), where it came from, and its privacy class.
///
/// Edits are saved with `DeliverableStoring.updateDeliverableText` (the text only, stamped `editedAt`); the source
/// transcript is never written.
@MainActor @Observable public final class DeliverableDocumentViewModel {
    public let id: UUID
    public private(set) var deliverable: Deliverable?
    /// The template version the document was written with ("version 2"), when the template still exists.
    public private(set) var templateVersionNumber: Int?
    /// Plan 026: what made the document and what changed in that template since (nil for an Ask answer).
    public private(set) var provenance: DocumentTemplateProvenance?
    /// The editor's text.
    public var draft = ""
    public private(set) var loadError: String?
    public private(set) var saveError: String?
    public private(set) var isDeleted = false

    @ObservationIgnored private let store: any DeliverableStoring

    public init(id: UUID, store: any DeliverableStoring) {
        self.id = id
        self.store = store
    }

    /// A document a run just stored.
    public convenience init(deliverable: Deliverable, store: any DeliverableStoring) {
        self.init(id: deliverable.id, store: store)
        self.deliverable = deliverable
        draft = deliverable.text
    }

    public var hasUnsavedChanges: Bool {
        guard let deliverable else { return false }
        return draft != deliverable.text
    }

    /// What the document screen says when the model stopped at its length limit while writing the current text
    /// (reviews R3-1, R4-2): the text is kept but incomplete. It stays after a hand edit (only the person knows
    /// whether they finished it) and follows a restored version's mark.
    public var cutOffNotice: String? {
        deliverable?.isCutOff == true ? Deliverable.cutOffMessage : nil
    }

    /// Shows a document an edit just stored (Edit by voice, review R5-9): the edit was made from the draft on screen
    /// (`DeliverableRunViewModel.Request.edit(baseText:)`), so its result replaces that draft instead of hiding
    /// behind it.
    public func applyEdit(_ edited: Deliverable) {
        guard edited.id == id else { return }
        deliverable = edited
        draft = edited.text
        saveError = nil
    }

    public func load() async {
        do {
            guard let found = try await store.fetchDeliverable(id: id) else {
                deliverable = nil
                isDeleted = true
                return
            }
            // Keep an edit in progress; otherwise show the stored text.
            if !hasUnsavedChanges { draft = found.text }
            deliverable = found
            var versionUsed: PromptVersion?
            if let versionID = found.promptVersionID { versionUsed = try await store.fetchVersion(id: versionID) }
            templateVersionNumber = versionUsed?.versionNumber
            // `fetchTemplate(id:)` includes deleted templates, so a deleted one is named as deleted.
            var template: PromptTemplate?
            if let promptID = found.promptID { template = try await store.fetchTemplate(id: promptID) }
            var active: PromptVersion?
            if let template { active = try await store.fetchVersion(id: template.activeVersionID) }
            provenance = DocumentTemplateProvenance.of(
                document: found, template: template, versionUsed: versionUsed, activeVersion: active)
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// Plan 026: the exact template version that made the document ("Show the instructions used"), read only. It
    /// survives edits and the template's delete (versions are immutable and never deleted). nil for an Ask answer or
    /// when it cannot be read.
    public func loadInstructionsUsed() async -> PromptVersion? {
        guard let versionID = deliverable?.promptVersionID else { return nil }
        return try? await store.fetchVersion(id: versionID)
    }

    /// Saves the editor's text when it changed. Returns false when the save failed (`saveError` says why).
    @discardableResult
    public func save() async -> Bool {
        guard hasUnsavedChanges else { return true }
        let text = draft
        do {
            guard let updated = try await store.updateDeliverableText(id: id, text: text) else {
                deliverable = nil
                isDeleted = true
                saveError = "This document no longer exists."
                return false
            }
            deliverable = updated
            saveError = nil
            return true
        } catch {
            saveError = error.localizedDescription
            return false
        }
    }

    /// Deletes the document after the user confirmed. The transcript stays.
    public func delete() async throws {
        try await store.deleteDeliverable(id: id)
        deliverable = nil
        isDeleted = true
    }

    public func dismissSaveError() {
        saveError = nil
    }
}
