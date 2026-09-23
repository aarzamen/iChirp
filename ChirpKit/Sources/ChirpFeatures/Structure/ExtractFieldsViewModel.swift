import ChirpCore
import Foundation
import Observation

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
    /// The words it came from.
    public var evidence: String

    /// Where the player seeks on tap (nil for a transcript without word timings).
    public var seekMs: Int? { field.span.startMs }
    public var isProvisional: Bool { field.verdict == .provisional }
    public var needsReview: Bool { field.verdict == .needsReview && !field.reviewed }
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
        for field in draft.fields {
            let item = Self.item(for: field, draft: draft)
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

    static func item(for field: StructuredField, draft: StructuredDraft) -> DraftItem {
        let arguments: [String: JSONValue] =
            (try? JSONDecoder().decode([String: JSONValue].self, from: Data(field.argumentsJSON.utf8))) ?? [:]
        func text(_ key: String) -> String? { arguments[key]?.stringValue }
        func display(_ key: String) -> String? {
            arguments[key]?["display"]?.stringValue ?? arguments[key]?["unresolved"]?.stringValue.map { "“\($0)”?" }
        }
        let evidence = draft.evidence(for: field)
        switch field.tool {
        case "record_vital":
            return DraftItem(
                field: field, section: .vitals, title: text("kind") ?? "Vital", detail: display("value") ?? "—",
                evidence: evidence)
        case "add_medication":
            let parts = [
                display("dose"), text("route").flatMap { $0 == "unknown" ? nil : $0 }, display("frequency"),
                text("status"),
            ].compactMap { $0 }
            return DraftItem(
                field: field, section: .medications, title: text("drug") ?? "Medication",
                detail: parts.joined(separator: " · "), evidence: evidence)
        case "add_allergy":
            return DraftItem(
                field: field, section: .allergies, title: text("substance") ?? "Allergy",
                detail: text("reaction") ?? "", evidence: evidence)
        case "add_problem":
            return DraftItem(
                field: field, section: .problems, title: text("text") ?? "", detail: "", evidence: evidence)
        case "add_plan_item":
            return DraftItem(field: field, section: .plan, title: text("text") ?? "", detail: "", evidence: evidence)
        default:
            return DraftItem(
                field: field, section: nil, title: "No field", detail: text("reason") ?? "", evidence: evidence)
        }
    }
}

/// The "Use in SOAP note" hand-off: the reviewed draft as `{{userNotes}}` for the SOAP template, always run by the
/// on-device model (the fields came from clinical dictation).
public enum SOAPDraftHandoff {
    public static let templateKey = "soap-note"
    /// Never a cloud or home-network model.
    public static let modelChoice = LanguageModelChoice.onDevice

    /// The draft as plain lines. Items in the needs-review bin are left out; unreviewed items say so.
    public static func notes(for sections: DraftSections, engineName: String) -> String? {
        let items = sections.draftItems
        guard !items.isEmpty else { return nil }
        var lines = [
            "Structured fields extracted on this iPhone by \(engineName). Draft: verify every value against the "
                + "transcript."
        ]
        func line(_ item: DraftItem) -> String {
            let body = item.detail.isEmpty ? item.title : "\(item.title): \(item.detail)"
            return "- \(body)" + (item.field.reviewed ? "" : " [unreviewed]")
        }
        for (title, group) in [
            ("Vitals", sections.vitals), ("Medications", sections.medications), ("Allergies", sections.allergies),
            ("Problems", sections.problems), ("Plan", sections.plan),
        ] where !group.isEmpty {
            lines.append("\(title):")
            lines += group.map(line)
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

    /// Mark a field reviewed (or not). A reviewed needs-review item joins the draft.
    public func toggleReviewed(_ item: DraftItem) async {
        guard var draft else { return }
        let reviewed = !item.field.reviewed
        do {
            try await service.setReviewed(item.field, reviewed: reviewed)
        } catch {
            phase = .failed(error.localizedDescription)
            return
        }
        if let index = draft.fields.firstIndex(where: { $0.id == item.field.id }) {
            draft.fields[index].reviewed = reviewed
        }
        show(draft)
    }

    /// The badge: engine, STUB label, model hash, fallback reason.
    public var engineBadge: String {
        guard let draft else { return "" }
        var parts = [draft.isStub ? "STUB · rules, not Needle" : draft.engineName]
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
