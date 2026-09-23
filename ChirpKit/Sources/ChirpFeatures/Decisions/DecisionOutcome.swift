import ChirpCore
import Foundation

/// What a decision's confidence allows. The UI always shows the verdict next to the answer.
public enum DecisionVerdict: String, Sendable, Equatable, Codable {
    /// Confident enough to offer the consequence as the default suggestion.
    case act
    /// Worth suggesting, with the uncertainty shown.
    case suggest
    /// Too uncertain to suggest anything.
    case unsure

    /// "Confident", "Likely", "Unsure".
    public var title: String {
        switch self {
        case .act: "Confident"
        case .suggest: "Likely"
        case .unsure: "Unsure"
        }
    }

    public var isAtLeastSuggest: Bool { self != .unsure }
}

/// Confidence thresholds for every decision recipe, in one place.
public enum DecisionGate {
    // Provisional values from plan 021. Step 7 sets both from the calibration table of the live evaluation
    // (docs/research/…-jev-trial-results.md): act = the lowest confidence bin whose accuracy is at least 0.9,
    // suggest = the lowest bin at or above 0.7. Change them only together with that doc and ADR-013.
    public static let act = 0.80
    public static let suggest = 0.55

    public static func verdict(for confidence: Double) -> DecisionVerdict {
        guard confidence.isFinite else { return .unsure }
        if confidence >= act { return .act }
        if confidence >= suggest { return .suggest }
        return .unsure
    }
}

/// One offered option with its title and probability, most likely first in `DecisionItem.options`.
public struct DecisionOption: Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var probability: Double
}

/// The answer to one question, ready for the result sheet.
public struct DecisionItem: Sendable, Equatable, Identifiable {
    /// The question id (`kind`, `template`, `p01` …).
    public var id: String
    /// For paragraph tags: the index of the paragraph on the Transcript screen.
    public var paragraphIndex: Int?
    public var choice: String
    public var choiceTitle: String
    public var confidence: Double
    public var verdict: DecisionVerdict
    /// Every offered option, most likely first.
    public var options: [DecisionOption]
}

/// A finished decision. Its consequences are suggestions only; applying one is the person's tap.
public struct DecisionReport: Sendable, Equatable {
    public var recipe: DecisionRecipe
    public var transcriptionID: UUID
    /// The versioned model id that answered.
    public var model: String
    public var latencyMs: Int
    /// The class the run was routed with.
    public var privacyClass: PrivacyClass
    public var items: [DecisionItem]

    /// Recording kind: "clinical encounter" at `suggest` or better offers "Mark as clinical?" (never automatic, never a
    /// downgrade: the item is not clinical yet, or Jev would not have run).
    public var suggestsMarkingClinical: Bool {
        guard recipe == .recordingKind, let item = items.first else { return false }
        return item.choice == "clinical_encounter" && item.verdict.isAtLeastSuggest
    }

    /// Template suggestion: the built-in's canonical key to pre-select in the Transform sheet, at `suggest` or better.
    public var suggestedTemplateKey: String? {
        guard recipe == .templateSuggestion, let item = items.first, item.verdict.isAtLeastSuggest,
            item.choice != "none"
        else { return nil }
        return item.choice
    }

    /// Paragraph tags at `suggest` or better (paragraph index → tag title), for this session's chips only.
    public var paragraphTags: [Int: String] {
        guard recipe == .paragraphTags else { return [:] }
        var tags: [Int: String] = [:]
        for item in items where item.verdict.isAtLeastSuggest {
            if let index = item.paragraphIndex { tags[index] = item.choiceTitle }
        }
        return tags
    }
}

/// What `DecisionService.run` returns.
public enum DecisionOutcome: Sendable, Equatable {
    case decided(DecisionReport)
    /// The item is clinical: nothing was sent (a `refused` ledger row was written).
    case blockedClinical
    /// The routing policy refused this engine for this item: nothing was sent (a `refused` ledger row was written).
    case blockedByRouting
}

/// Why a decision could not run. Content-free.
public enum DecisionError: Error, Equatable, LocalizedError {
    case transcriptNotFound
    case emptyTranscript
    /// Jev is turned off in Settings → Models.
    case disabled
    /// No Jev API key in the Keychain.
    case missingKey

    public var errorDescription: String? {
        switch self {
        case .transcriptNotFound: "This transcript no longer exists."
        case .emptyTranscript: "This transcript has no text yet."
        case .disabled: "Jev is off. Turn it on in Settings → Models."
        case .missingKey: "Add a Jev API key in Settings → Models."
        }
    }

    /// Content-free name for logs and the run ledger.
    public var kindName: String {
        switch self {
        case .transcriptNotFound: "transcript_not_found"
        case .emptyTranscript: "empty_transcript"
        case .disabled: "decision_disabled"
        case .missingKey: "missing_key"
        }
    }
}
