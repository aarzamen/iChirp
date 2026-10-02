// New for iChirp (plan 025 Step B3, decision D8): learned rules ("Also fix future transcripts") applied to a new
// transcript as visible, revertible corrections. Matching semantics from MacParakeet (GPL-3.0):
// Sources/MacParakeetCore/TextProcessing/CustomWordReplacer.swift @ bbae9e0e (whole word, case-insensitive, the
// replacement taken literally); upstream has no learned rules.

import ChirpCore
import Foundation

/// Turns the person's learned rules (`CustomWord` with `source == .learned`) into `rule` corrections of a transcript's
/// words as heard.
///
/// Each enabled rule with a replacement is matched in every line of the `.heard` view as `CustomWordReplacer` matches
/// a custom word (`\b<word>\b`, case-insensitive). Each match becomes the line's text with that match replaced, reduced
/// to the smallest span by `CorrectionPlanner` (`origin: .rule`, the rule's `ruleID`, one batch per rule). Unlike Clean,
/// rules do not chain: every rule sees the words as heard. A match that touches a word the person (or an earlier rule)
/// already corrected is left alone, and a match whose span would overlap an earlier one is skipped, so the plan never
/// removes a correction. A rule with a number in either text is never applied (`containsNumber`).
public enum LearnedRuleMatcher {
    public static func plan(_ heard: TranscriptText, rules: [CustomWord], now: Date) -> TranscriptCorrectionPlan {
        guard heard.hasWordTimings, !heard.tokens.isEmpty else { return TranscriptCorrectionPlan() }
        let compiled = rules.compactMap { rule -> (rule: CustomWord, regex: NSRegularExpression, text: String)? in
            guard rule.isEnabled,
                let replacement = rule.replacement?.trimmingCharacters(in: .whitespacesAndNewlines),
                !replacement.isEmpty,
                // C1, defense in depth for rules saved before the number ruling: never applied.
                !containsNumber(rule.word), !containsNumber(replacement),
                let regex = regex(for: rule.word)
            else { return nil }
            return (rule, regex, replacement)
        }
        guard !compiled.isEmpty else { return TranscriptCorrectionPlan() }

        var plan = TranscriptCorrectionPlan()
        var claimed: [Range<Int>] = []
        let batches = Dictionary(compiled.map { ($0.rule.id, UUID()) }, uniquingKeysWith: { first, _ in first })
        for line in heard.lines where !line.tokenUTF16Ranges.isEmpty {
            let text = line.text as NSString
            // UTF-16 ranges already taken on this line (an earlier rule or match).
            var taken: [NSRange] = []
            for (rule, regex, replacement) in compiled {
                for result in regex.matches(in: line.text, range: NSRange(location: 0, length: text.length)) {
                    let range = result.range
                    guard range.length > 0,
                        !taken.contains(where: { NSIntersectionRange($0, range).length > 0 }),
                        !touchesCorrection(range, line: line, tokens: heard.tokens)
                    else { continue }
                    let edited = text.replacingCharacters(in: range, with: replacement)
                    guard
                        let matchPlan = try? CorrectionPlanner.plan(
                            line: line, tokens: heard.tokens, heard: { heard.heardText($0) }, editedText: edited,
                            origin: .rule, batchID: batches[rule.id], now: now),
                        matchPlan.remove.isEmpty, !matchPlan.add.isEmpty,
                        !matchPlan.add.contains(where: { add in claimed.contains { $0.overlaps(add.range) } })
                    else { continue }
                    taken.append(range)
                    for var add in matchPlan.add {
                        add.ruleID = rule.id
                        claimed.append(add.range)
                        plan.add.append(add)
                    }
                }
            }
        }
        plan.add.sort { $0.range.lowerBound < $1.range.lowerBound }
        return plan
    }

    /// True when `range` of `text` is a place a rule for `word` would match: `\b<word>\b`, case-insensitive (diacritics
    /// count), starting and ending exactly there. Replace offers "Also fix future transcripts" only when every replaced
    /// match passes, so the rule finds the same places next time.
    public static func isWholeWord(_ range: NSRange, in text: String, word: String) -> Bool {
        guard let regex = regex(for: word) else { return false }
        let length = (text as NSString).length
        guard range.location >= 0, range.location + range.length <= length else { return false }
        return regex.matches(in: text, range: NSRange(location: 0, length: length)).contains { $0.range == range }
    }

    /// Fix round 1, C1: a learned rule may not hold a number in what it finds or what it writes, so a dose ("0.5 mg"
    /// → "5 mg") is never changed automatically in a later transcript. Any Character Unicode calls a number counts
    /// ("5", "½", "²").
    public static func containsNumber(_ text: String) -> Bool {
        text.contains(where: \.isNumber)
    }

    /// `CustomWordReplacer`'s pattern for one word.
    private static func regex(for word: String) -> NSRegularExpression? {
        let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return try? NSRegularExpression(
            pattern: "\\b\(NSRegularExpression.escapedPattern(for: trimmed))\\b", options: .caseInsensitive)
    }

    /// The match overlaps a token that is already a correction.
    public static func touchesCorrection(_ range: NSRange, line: TranscriptTextLine, tokens: [TranscriptToken]) -> Bool
    {
        let matchRange = range.location..<(range.location + range.length)
        for (offset, tokenRange) in line.tokenUTF16Ranges.enumerated() where tokenRange.overlaps(matchRange) {
            let index = line.tokenRange.lowerBound + offset
            if tokens.indices.contains(index), tokens[index].editID != nil { return true }
        }
        return false
    }
}
