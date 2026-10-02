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
/// removes a correction. A rule with a number or a dose unit in either text is never applied
/// (`containsNumberOrDoseUnit`).
public enum LearnedRuleMatcher {
    public static func plan(_ heard: TranscriptText, rules: [CustomWord], now: Date) -> TranscriptCorrectionPlan {
        guard heard.hasWordTimings, !heard.tokens.isEmpty else { return TranscriptCorrectionPlan() }
        let compiled = rules.compactMap { rule -> (rule: CustomWord, regex: NSRegularExpression, text: String)? in
            guard rule.isEnabled,
                let replacement = rule.replacement?.trimmingCharacters(in: .whitespacesAndNewlines),
                !replacement.isEmpty,
                // C1 and U1, defense in depth for rules saved before those rulings: never applied.
                !containsNumberOrDoseUnit(rule.word), !containsNumberOrDoseUnit(replacement),
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

    /// Fix round 2, U1: the dose and measurement words no learned rule may hold, on either side ("mg" → "mcg" changes a
    /// dose's meaning without a digit). One closed list, matched as whole words in any case (`containsDoseUnit`): mass,
    /// volume and units, percent, and the dose-frequency abbreviations whose swap changes meaning. Drug names are not
    /// on it ("metoprolol" → "metformin" stays allowed: the owner's to revisit).
    public static let doseUnitWords: [String] = [
        // Mass
        "mg", "mcg", "µg", "μg", "ug", "g", "gm", "gram", "grams", "kg", "milligram", "milligrams", "microgram",
        "micrograms", "ng", "nanogram", "nanograms",
        // Volume
        "ml", "cc", "l", "liter", "liters", "litre", "litres", "milliliter", "milliliters", "millilitre",
        "millilitres",
        // Units and amounts of substance
        "unit", "units", "iu", "international unit", "international units", "meq", "mmol", "mol",
        // Percent
        "percent", "%",
        // Dose frequency
        "qd", "bid", "tid", "qid", "q.d.", "b.i.d.", "t.i.d.", "q.i.d.", "qhs", "prn", "daily", "weekly", "hourly",
    ]

    /// `doseUnitWords` as one case-insensitive pattern: each word not touching another letter or digit on either side
    /// (so "mg" is found in "5 mg" and "mg/kg" but not in "magnesium"; "%" anywhere).
    private static let doseUnitPattern: NSRegularExpression? = {
        let alternatives = doseUnitWords.sorted { $0.count > $1.count }.map { word -> String in
            let escaped = NSRegularExpression.escapedPattern(for: word)
            return word == "%" ? escaped : "(?<![\\p{L}\\p{N}])" + escaped + "(?![\\p{L}\\p{N}])"
        }
        return try? NSRegularExpression(pattern: alternatives.joined(separator: "|"), options: .caseInsensitive)
    }()

    /// True when `text` holds a word of `doseUnitWords` (U1).
    public static func containsDoseUnit(_ text: String) -> Bool {
        guard let pattern = doseUnitPattern else { return true }  // never fail open
        return pattern.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil
    }

    /// The one check behind every learned-rule refusal (C1 and U1): a number or a dose unit.
    public static func containsNumberOrDoseUnit(_ text: String) -> Bool {
        containsNumber(text) || containsDoseUnit(text)
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
