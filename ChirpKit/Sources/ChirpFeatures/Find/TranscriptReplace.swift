// New for iChirp (plan 025 Step B3): what Replace and Replace All did, and the "Also fix future transcripts" offer
// (decision D8). Upstream MacParakeet has no replace and no learned rules.

import ChirpCore
import ChirpText
import Foundation

/// What a Replace or Replace All did (`TranscriptViewModel.replace` / `replaceAll`).
public struct ReplaceOutcome: Sendable, Equatable {
    /// Applying it (`TranscriptViewModel.undo`) reverts the whole replace at once.
    public var undo: TranscriptCorrectionPlan
    /// Matches replaced.
    public var count: Int
    /// Matches left alone: their text no longer matched the query (the transcript changed meanwhile), or they sit in a
    /// passage corrected earlier (`skippedInCorrections`, included here).
    public var skipped: Int
    /// Fix round 1, I2: matches left alone because they touch a correction from another batch, so a later revert of
    /// this replace never takes the person's earlier correction with it.
    public var skippedInCorrections: Int
    /// "Also fix … in future transcripts?", when D8 allows it.
    public var ruleSuggestion: LearnedRuleSuggestion?
    /// Why the rule offer was withheld when that is worth saying (C1: a number in either text); nil otherwise.
    public var ruleWithheld: String?

    public init(
        undo: TranscriptCorrectionPlan, count: Int, skipped: Int = 0, skippedInCorrections: Int = 0,
        ruleSuggestion: LearnedRuleSuggestion? = nil, ruleWithheld: String? = nil
    ) {
        self.undo = undo
        self.count = count
        self.skipped = skipped
        self.skippedInCorrections = skippedInCorrections
        self.ruleSuggestion = ruleSuggestion
        self.ruleWithheld = ruleWithheld
    }
}

/// A learned rule the person may save after a Replace: new transcripts get `word` → `replacement` as corrections.
public struct LearnedRuleSuggestion: Sendable, Equatable {
    public var word: String
    public var replacement: String

    public init(word: String, replacement: String) {
        self.word = word
        self.replacement = replacement
    }

    /// The offer, when D8 allows it: no number in either text (C1, `withheldReason`); the query has no spaces at either
    /// end and is at least three characters with a letter; the replacement is not blank and differs from it; something was replaced; and every replaced match is a
    /// place the rule would match (whole words, case-insensitive: `LearnedRuleMatcher.isWholeWord`), so the rule finds
    /// the same places in the next transcript. Whether a rule with that text exists is checked when it is saved.
    public static func make(query: String, replacement: String, replaced: [(text: String, range: NSRange)])
        -> LearnedRuleSuggestion?
    {
        let trimmedReplacement = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard withheldReason(query: query, replacement: replacement) == nil,
            query == query.trimmingCharacters(in: .whitespacesAndNewlines), query.count >= 3,
            query.contains(where: \.isLetter), !trimmedReplacement.isEmpty, trimmedReplacement != query,
            !replaced.isEmpty,
            replaced.allSatisfy({ LearnedRuleMatcher.isWholeWord($0.range, in: $0.text, word: query) })
        else { return nil }
        return LearnedRuleSuggestion(word: query, replacement: trimmedReplacement)
    }

    /// Fix round 1, C1: no learned rule may hold a number, so a dose is never changed automatically.
    public static let numbersReason = "Rules can’t contain numbers, so a dose is never changed automatically."

    /// Why a replacement is never offered as a rule even though it changed something: a number in the query or the
    /// replacement (C1). Nil when that is not the reason.
    public static func withheldReason(query: String, replacement: String) -> String? {
        LearnedRuleMatcher.containsNumber(query) || LearnedRuleMatcher.containsNumber(replacement)
            ? numbersReason : nil
    }

    /// The banner's question: "Also fix “met for men” in future transcripts?"
    public var question: String { "Also fix “\(word)” in future transcripts?" }

    /// Added under the question on a clinical item: learned rules are global, outside any item's class (D6).
    public static let clinicalNote = "Saved in Settings → Text rules for all transcripts. Don’t add patient names."
}
