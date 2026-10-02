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
    /// Matches left alone because their text no longer matched the query (the transcript changed meanwhile).
    public var skipped: Int
    /// "Also fix … in future transcripts?", when D8 allows it.
    public var ruleSuggestion: LearnedRuleSuggestion?

    public init(
        undo: TranscriptCorrectionPlan, count: Int, skipped: Int = 0, ruleSuggestion: LearnedRuleSuggestion? = nil
    ) {
        self.undo = undo
        self.count = count
        self.skipped = skipped
        self.ruleSuggestion = ruleSuggestion
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

    /// The offer, when D8 allows it: the query has no spaces at either end, is at least three characters with a
    /// letter; the replacement is not blank and differs from it; something was replaced; and every replaced match is a
    /// place the rule would match (whole words, case-insensitive: `LearnedRuleMatcher.isWholeWord`), so the rule finds
    /// the same places in the next transcript. Whether a rule with that text exists is checked when it is saved.
    public static func make(query: String, replacement: String, replaced: [(text: String, range: NSRange)])
        -> LearnedRuleSuggestion?
    {
        let trimmedReplacement = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query == query.trimmingCharacters(in: .whitespacesAndNewlines), query.count >= 3,
            query.contains(where: \.isLetter), !trimmedReplacement.isEmpty, trimmedReplacement != query,
            !replaced.isEmpty,
            replaced.allSatisfy({ LearnedRuleMatcher.isWholeWord($0.range, in: $0.text, word: query) })
        else { return nil }
        return LearnedRuleSuggestion(word: query, replacement: trimmedReplacement)
    }

    /// The banner's question: "Also fix “met for men” in future transcripts?"
    public var question: String { "Also fix “\(word)” in future transcripts?" }

    /// Added under the question on a clinical item: learned rules are global, outside any item's class (D6).
    public static let clinicalNote = "Saved in Settings → Text rules for all transcripts. Don’t add patient names."
}
