import ChirpCore
import Foundation

// Polish lane u2 (UX audit F51 and the voice question): the words for `EffectivePrivacyClass`, so a label and every
// question that asks before content leaves the phone say why an item counts as clinical when it is not marked so.

extension PrivacyClass {
    /// "General", "Personal", "Clinical".
    public var displayName: String {
        switch self {
        case .general: "General"
        case .personal: "Personal"
        case .clinical: "Clinical"
        }
    }
}

/// An item's privacy class as the routers use it, with the reason in words when it is stricter than the item's own
/// mark: a Personal transcript with a SOAP note counts as Clinical ("Clinical (it has a SOAP note)"). The class itself
/// always comes from `EffectivePrivacyClass`; this only explains it.
public struct EffectivePrivacyExplanation: Sendable, Equatable {
    /// The class the item is marked with.
    public let stored: PrivacyClass
    /// The class the privacy rules use (`EffectivePrivacyClass`).
    public let effective: PrivacyClass
    /// The titles of the documents made from the item that raise it ("SOAP note"), each once, in the order given.
    public let raisedBy: [String]

    public init(_ transcription: Transcription, deliverables: [Deliverable]) {
        stored = transcription.privacyClass
        effective = EffectivePrivacyClass.of(transcription, deliverables: deliverables)
        var titles: [String] = []
        for deliverable in deliverables
        where deliverable.privacyClass == effective && effective.strictness > stored.strictness {
            let title = deliverable.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = title.isEmpty ? "document" : title
            if !titles.contains(name) { titles.append(name) }
        }
        raisedBy = titles
    }

    /// The item's class as stored now, raised by its documents as stored now; nil when the item no longer exists.
    public static func current(
        transcriptionID: UUID,
        transcripts: any TranscriptionStoring,
        deliverables: any DeliverableStoring
    ) async throws -> EffectivePrivacyExplanation? {
        guard let transcription = try await transcripts.fetch(id: transcriptionID) else { return nil }
        let made = try await deliverables.fetchDeliverables(transcriptionID: transcriptionID)
        return EffectivePrivacyExplanation(transcription, deliverables: made)
    }

    /// Whether a document made from the item makes it stricter than its own mark.
    public var isRaised: Bool { effective != stored }

    /// "Clinical (it has a SOAP note)" when raised; otherwise the class ("Personal").
    public var label: String {
        guard isRaised else { return effective.displayName }
        return "\(effective.displayName) (it has \(Self.article(raisedBy.first ?? "document")) \(Self.names(raisedBy)))"
    }

    /// "Marked Personal, but it counts as clinical because a SOAP note was made from it." nil when not raised.
    public var sentence: String? {
        guard isRaised else { return nil }
        let names = Self.names(raisedBy)
        let made = raisedBy.count > 1 ? "were" : "was"
        return "Marked \(stored.displayName), but it counts as \(effective.displayName.lowercased()) because "
            + "\(Self.article(raisedBy.first ?? "document")) \(names) \(made) made from it."
    }

    /// "SOAP note", "SOAP note and Summary", "SOAP note, Summary and 1 more".
    static func names(_ titles: [String]) -> String {
        switch titles.count {
        case 0: return "document"
        case 1: return titles[0]
        case 2: return "\(titles[0]) and \(titles[1])"
        default: return "\(titles[0]), \(titles[1]) and \(titles.count - 2) more"
        }
    }

    /// "a" or "an" before a title (by its first letter; "an" before a vowel).
    static func article(_ title: String) -> String {
        guard let first = title.lowercased().first else { return "a" }
        return "aeiou".contains(first) ? "an" : "a"
    }
}

/// Why one language-model run counts as clinical, in words, for the per-run question (F51, F33): the item's
/// documents, the template's clinical output, or the document being edited. Nil when the item itself is marked
/// clinical (the question's title already says so) or the run is not clinical.
public enum ClinicalRunReason {
    /// What the run makes or edits: its class, its name ("SOAP note"), and whether it is an existing document being
    /// edited (true) or a template's new output (false).
    public typealias Output = (privacyClass: PrivacyClass, name: String, isExistingDocument: Bool)

    public static func sentence(_ explanation: EffectivePrivacyExplanation, output: Output?) -> String? {
        guard explanation.stored != .clinical else { return nil }
        if let sentence = explanation.sentence, explanation.effective == .clinical { return sentence }
        guard let output, output.privacyClass == .clinical else { return nil }
        if output.isExistingDocument { return "This \(output.name) is clinical." }
        return "The \(output.name) template makes clinical documents."
    }
}
