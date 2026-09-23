import ChirpCore
import Foundation
import Observation

/// A value the person may correct before accepting a field (review L3 I8).
public struct DraftEditableField: Sendable, Equatable, Identifiable {
    public var id: String { key }
    /// The argument: "drug", "dose", "route", "frequency", "status", "kind", "value", "substance", "reaction", "text".
    public var key: String
    public var label: String
    /// What the card shows now ("" when the field has none).
    public var value: String
}

/// One row of the draft card.
public struct DraftItem: Sendable, Equatable, Identifiable {
    public enum Section: String, Sendable, CaseIterable {
        case vitals, medications, allergies, problems, plan
    }

    public var id: UUID { field.id }
    public var field: StructuredField
    public var section: Section?
    /// "BP", "lisinopril", "penicillin", the problem or plan text.
    public var title: String
    /// "142/88 mmHg", "10 mg · PO · once daily · started".
    public var detail: String
    /// The words its number came from (what tap-to-seek plays).
    public var evidence: String
    /// The whole sentence it came from (review L3 I2: shows which drug or vital a value belongs to).
    public var evidenceSentence = ""
    /// UTF-16 range of `evidence` inside `evidenceSentence`, for the highlight (nil: the whole sentence).
    public var highlight: Range<Int>?
    /// The values the review sheet lets the person correct.
    public var editableFields: [DraftEditableField] = []
    /// The person changed a value while reviewing it.
    public var isEdited = false

    /// Where the player seeks on tap (nil for a transcript without word timings).
    public var seekMs: Int? { field.span.startMs }
    public var isProvisional: Bool { field.verdict == .provisional }
    public var needsReview: Bool { field.verdict == .needsReview && !field.reviewed }
    /// A check failed: accepting it needs the review sheet (reasons shown, values editable), never one tap.
    public var needsReviewSheet: Bool { !field.reviewed && !field.reviewReasons.isEmpty }

    /// The field's arguments with the person's edits applied (tag values become `{"display", "editedInReview"}`),
    /// or nil when nothing changed.
    public func argumentsJSON(applying edits: [String: String]) -> String? {
        var arguments = DraftSections.arguments(of: field)
        var changed = false
        for editable in editableFields {
            guard let edited = edits[editable.key]?.trimmingCharacters(in: .whitespacesAndNewlines),
                edited != editable.value
            else { continue }
            changed = true
            if edited.isEmpty {
                arguments[editable.key] = nil
            } else if DraftSections.tagKeys.contains(editable.key) {
                arguments[editable.key] = .object(["display": .string(edited), "editedInReview": .bool(true)])
            } else {
                arguments[editable.key] = .string(edited)
            }
        }
        guard changed else { return nil }
        arguments["editedInReview"] = .bool(true)
        return JSONValue.object(arguments).compactJSON
    }
}

/// The draft card's content: fields by section, the needs-review bin, and what was skipped.
public struct DraftSections: Sendable, Equatable {
    public var vitals: [DraftItem] = []
    public var medications: [DraftItem] = []
    public var allergies: [DraftItem] = []
    public var problems: [DraftItem] = []
    public var plan: [DraftItem] = []
    /// Below provisional or failed a check, and not yet reviewed: never part of the draft.
    public var needsReview: [DraftItem] = []
    /// Sentences the engine judged to hold nothing to record.
    public var skippedCount = 0

    public init(draft: StructuredDraft) {
        let sentences = StructuredSourceText(text: draft.sourceText).sentenceRanges()
        for field in draft.fields {
            let item = Self.item(for: field, draft: draft, sentences: sentences)
            if field.tool == "none", field.reviewReasons.isEmpty {
                skippedCount += 1
                continue
            }
            if item.needsReview || item.section == nil {
                needsReview.append(item)
                continue
            }
            switch item.section {
            case .vitals: vitals.append(item)
            case .medications: medications.append(item)
            case .allergies: allergies.append(item)
            case .problems: problems.append(item)
            case .plan: plan.append(item)
            case nil: break
            }
        }
    }

    public var draftItems: [DraftItem] { vitals + medications + allergies + problems + plan }
    public var isEmpty: Bool { draftItems.isEmpty && needsReview.isEmpty }

    static let tagKeys: Set<String> = ["dose", "value", "frequency"]

    static func arguments(of field: StructuredField) -> [String: JSONValue] {
        (try? JSONDecoder().decode([String: JSONValue].self, from: Data(field.argumentsJSON.utf8))) ?? [:]
    }

    static func item(for field: StructuredField, draft: StructuredDraft, sentences: [Range<Int>] = []) -> DraftItem {
        let arguments = Self.arguments(of: field)
        func text(_ key: String) -> String? { arguments[key]?.stringValue }
        func display(_ key: String) -> String? {
            arguments[key]?["display"]?.stringValue ?? arguments[key]?["unresolved"]?.stringValue.map { "“\($0)”?" }
        }
        func editable(_ keys: [(String, String)]) -> [DraftEditableField] {
            keys.map { key, label in
                DraftEditableField(
                    key: key, label: label,
                    value: (tagKeys.contains(key) ? display(key) : text(key)).map { $0 == "unknown" ? "" : $0 } ?? "")
            }
        }
        let evidence = draft.evidence(for: field)
        var item: DraftItem
        switch field.tool {
        case "record_vital":
            item = DraftItem(
                field: field, section: .vitals, title: text("kind") ?? "Vital", detail: display("value") ?? "—",
                evidence: evidence)
            item.editableFields = editable([("kind", "Vital"), ("value", "Value")])
        case "add_medication":
            let parts = [
                display("dose"), text("route").flatMap { $0 == "unknown" ? nil : $0 }, display("frequency"),
                text("status"),
            ].compactMap { $0 }
            item = DraftItem(
                field: field, section: .medications, title: text("drug") ?? "Medication",
                detail: parts.joined(separator: " · "), evidence: evidence)
            item.editableFields = editable([
                ("drug", "Drug"), ("dose", "Dose"), ("route", "Route"), ("frequency", "How often"),
                ("status", "Status"),
            ])
        case "add_allergy":
            item = DraftItem(
                field: field, section: .allergies, title: text("substance") ?? "Allergy",
                detail: text("reaction") ?? "", evidence: evidence)
            item.editableFields = editable([("substance", "Substance"), ("reaction", "Reaction")])
        case "add_problem":
            item = DraftItem(
                field: field, section: .problems, title: text("text") ?? "", detail: "", evidence: evidence)
            item.editableFields = editable([("text", "Problem")])
        case "add_plan_item":
            item = DraftItem(field: field, section: .plan, title: text("text") ?? "", detail: "", evidence: evidence)
            item.editableFields = editable([("text", "Plan item")])
        default:
            item = DraftItem(
                field: field, section: nil, title: "No field", detail: text("reason") ?? "", evidence: evidence)
        }
        let sentence = draft.evidenceSentence(for: field, sentences: sentences)
        item.evidenceSentence = sentence.text
        item.highlight = sentence.highlight
        item.isEdited = arguments["editedInReview"] == .bool(true)
        return item
    }
}

/// The "Use in SOAP note" hand-off: **only the fields the person reviewed** (review L3 I7) as `{{userNotes}}` for the
/// SOAP template, always run by the on-device model (the fields came from clinical dictation).
public enum SOAPDraftHandoff {
    public static let templateKey = "soap-note"
    /// Never a cloud or home-network model.
    public static let modelChoice = LanguageModelChoice.onDevice

    /// The reviewed fields as plain lines, or nil when none is reviewed. Unreviewed fields are left out. A field
    /// accepted despite a failed check carries its reasons; an edited one says so (review L3 I8).
    public static func notes(for sections: DraftSections, engineName: String) -> String? {
        func reviewed(_ items: [DraftItem]) -> [DraftItem] { items.filter(\.field.reviewed) }
        guard !reviewed(sections.draftItems).isEmpty else { return nil }
        var lines = [
            "Structured fields extracted on this iPhone by \(engineName) and reviewed by the clinician; unreviewed "
                + "fields are left out. Keep every value exactly as written."
        ]
        func line(_ item: DraftItem) -> String {
            let body = item.detail.isEmpty ? item.title : "\(item.title): \(item.detail)"
            var notes: [String] = []
            if item.isEdited { notes.append("edited in review") }
            if !item.field.reviewReasons.isEmpty {
                let reasons = item.field.reviewReasons.joined(separator: " ")
                notes.append(item.isEdited ? "flagged: \(reasons)" : "accepted in review despite: \(reasons)")
            }
            return "- \(body)" + (notes.isEmpty ? "" : " (\(notes.joined(separator: "; ")))")
        }
        for (title, group) in [
            ("Vitals", sections.vitals), ("Medications", sections.medications), ("Allergies", sections.allergies),
            ("Problems", sections.problems), ("Plan", sections.plan),
        ] where !reviewed(group).isEmpty {
            lines.append("\(title):")
            lines += reviewed(group).map(line)
        }
        return lines.joined(separator: "\n")
    }
}

/// Transcript → Extract fields: runs the extraction, shows the draft card, and records reviews.
@MainActor @Observable public final class ExtractFieldsViewModel {
    public enum Phase: Equatable {
        case idle
        case running(done: Int, total: Int)
        case ready
        case failed(String)
    }

    public private(set) var phase: Phase = .idle
    public private(set) var draft: StructuredDraft?
    public private(set) var sections: DraftSections?

    @ObservationIgnored private let service: StructuredExtractionService
    @ObservationIgnored private let transcriptionID: UUID
    @ObservationIgnored private var task: Task<Void, Never>?

    public init(service: StructuredExtractionService, transcriptionID: UUID) {
        self.service = service
        self.transcriptionID = transcriptionID
    }

    /// Shows the newest saved run, if any.
    public func load() async {
        guard let draft = try? await service.latestDraft(transcriptionID: transcriptionID) else { return }
        show(draft)
    }

    public func extract() async {
        phase = .running(done: 0, total: 0)
        let task = Task {
            do {
                let draft = try await service.extractSOAP(transcriptionID: transcriptionID) { done, total in
                    Task { @MainActor [weak self] in
                        guard let self, case .running = self.phase else { return }
                        self.phase = .running(done: done, total: total)
                    }
                }
                show(draft)
            } catch is CancellationError {
                phase = .idle
            } catch {
                phase = .failed((error as? any LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }
        self.task = task
        await task.value
    }

    public func cancel() {
        task?.cancel()
    }

    /// A field whose check failed, waiting for the review sheet (reasons shown, values editable).
    public private(set) var reviewRequest: DraftItem?

    /// Mark a field reviewed (or not). A reviewed needs-review item joins the draft. A field that failed a check is
    /// never accepted in one tap (review L3 I8): it opens the review sheet instead (`reviewRequest`).
    public func toggleReviewed(_ item: DraftItem) async {
        if item.needsReviewSheet {
            reviewRequest = item
            return
        }
        await record(item, reviewed: !item.field.reviewed, argumentsJSON: nil)
    }

    /// The review sheet's "Accept": records the review with the person's edits (empty: accepted as shown, despite its
    /// reasons). The reasons stay with the field and travel into the SOAP hand-off.
    public func confirmReview(_ item: DraftItem, edits: [String: String]) async {
        reviewRequest = nil
        await record(item, reviewed: true, argumentsJSON: item.argumentsJSON(applying: edits))
    }

    public func cancelReview() {
        reviewRequest = nil
    }

    private func record(_ item: DraftItem, reviewed: Bool, argumentsJSON: String?) async {
        guard var draft else { return }
        do {
            try await service.setReviewed(item.field, reviewed: reviewed, argumentsJSON: argumentsJSON)
        } catch {
            phase = .failed(error.localizedDescription)
            return
        }
        if let index = draft.fields.firstIndex(where: { $0.id == item.field.id }) {
            draft.fields[index].reviewed = reviewed
            if let argumentsJSON { draft.fields[index].argumentsJSON = argumentsJSON }
        }
        show(draft)
    }

    /// How many draft fields the person reviewed (only those go to the SOAP note).
    public var reviewedDraftCount: Int { sections?.draftItems.filter(\.field.reviewed).count ?? 0 }

    /// The Transcript and Document menu item (review L3 I10: says experimental; the sheet says which engine ran).
    public static let menuTitle = "Extract fields (experimental)"

    /// The badge: engine, STUB label or Needle's experimental label, model hash, fallback reason.
    public var engineBadge: String {
        guard let draft else { return "" }
        var parts = [draft.isStub ? "STUB · rules, not Needle" : draft.engineName]
        if !draft.isStub, NeedleExperimental.isExperimental { parts.append(NeedleExperimental.chip) }
        if let hash = draft.run.modelSHA256 { parts.append("model \(hash.prefix(8))") }
        if let reason = draft.fallbackReason { parts.append("Needle unavailable: \(reason)") }
        return parts.joined(separator: " · ")
    }

    public var soapNotes: String? {
        guard let sections, let draft else { return nil }
        return SOAPDraftHandoff.notes(for: sections, engineName: draft.isStub ? "the STUB (rules)" : draft.engineName)
    }

    private func show(_ draft: StructuredDraft) {
        self.draft = draft
        sections = DraftSections(draft: draft)
        phase = .ready
    }
}
