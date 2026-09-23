// Ported from MacParakeet (GPL-3.0): benchmarks/asr/score.py @ bbae9e0e
// Changes: the dependency-free `--simple` normalizer (lowercase, curly quotes folded, punctuation to spaces, intra-word
// apostrophes kept) and the dynamic-programming substitution/deletion/insertion counts, in Swift for the on-device
// benchmark (M7 Step 6). Upstream's default Whisper EnglishTextNormalizer (numbers, spellings) is not ported: the
// reference set avoids numbers so both normalizers agree on it.

import Foundation

/// Word error rate between a reference text and a hypothesis: (substitutions + deletions + insertions) / reference
/// words, after one normalizer for every engine.
public struct WordErrorRate: Sendable, Equatable, Codable {
    public var substitutions: Int
    public var deletions: Int
    public var insertions: Int
    public var referenceWords: Int

    public init(substitutions: Int, deletions: Int, insertions: Int, referenceWords: Int) {
        self.substitutions = substitutions
        self.deletions = deletions
        self.insertions = insertions
        self.referenceWords = referenceWords
    }

    public var errors: Int { substitutions + deletions + insertions }

    /// 0 = perfect; can exceed 1 when the hypothesis adds many words. 0 for an empty reference with no hypothesis.
    public var rate: Double {
        guard referenceWords > 0 else { return errors == 0 ? 0 : 1 }
        return Double(errors) / Double(referenceWords)
    }

    /// Scores `hypothesis` against `reference` with the simple normalizer.
    public static func score(reference: String, hypothesis: String) -> WordErrorRate {
        let ref = normalizedWords(reference)
        let hyp = normalizedWords(hypothesis)
        let (insertions, deletions, substitutions) = editCounts(hypothesis: hyp, reference: ref)
        return WordErrorRate(
            substitutions: substitutions, deletions: deletions, insertions: insertions, referenceWords: ref.count)
    }

    /// Corpus WER: the error and word counts summed over items (the standard aggregate, not a mean of rates).
    public static func corpus(_ items: [WordErrorRate]) -> WordErrorRate {
        items.reduce(WordErrorRate(substitutions: 0, deletions: 0, insertions: 0, referenceWords: 0)) {
            WordErrorRate(
                substitutions: $0.substitutions + $1.substitutions, deletions: $0.deletions + $1.deletions,
                insertions: $0.insertions + $1.insertions, referenceWords: $0.referenceWords + $1.referenceWords)
        }
    }

    /// Lowercased words: curly quotes folded, anything that is not a letter, digit, underscore, apostrophe or space
    /// becomes a space, apostrophes at a word's edges dropped (upstream `_simple_tokens`).
    public static func normalizedWords(_ text: String) -> [String] {
        var folded = text.lowercased()
        for (curly, straight) in ["\u{2019}": "'", "\u{2018}": "'", "\u{201C}": "\"", "\u{201D}": "\""] {
            folded = folded.replacingOccurrences(of: curly, with: straight)
        }
        let cleaned = String(
            folded.unicodeScalars.map { scalar -> Character in
                if CharacterSet.alphanumerics.contains(scalar) || scalar == "_" || scalar == "'"
                    || CharacterSet.whitespacesAndNewlines.contains(scalar)
                {
                    return Character(scalar)
                }
                return " "
            })
        return cleaned.split(whereSeparator: { $0.isWhitespace })
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "'")) }
            .filter { !$0.isEmpty }
    }

    /// Minimum edit alignment, then a backtrace that prefers matches, then substitutions, insertions, deletions
    /// (upstream's pure-Python fallback, so the split matches it).
    static func editCounts(hypothesis hyp: [String], reference ref: [String]) -> (Int, Int, Int) {
        let m = hyp.count
        let n = ref.count
        var dp = [[Int]](repeating: [Int](repeating: 0, count: n + 1), count: m + 1)
        for i in 0...m { dp[i][0] = i }
        for j in 0...n { dp[0][j] = j }
        if m > 0, n > 0 {
            for i in 1...m {
                for j in 1...n {
                    dp[i][j] =
                        hyp[i - 1] == ref[j - 1]
                        ? dp[i - 1][j - 1] : 1 + min(dp[i - 1][j], dp[i][j - 1], dp[i - 1][j - 1])
                }
            }
        }
        var i = m
        var j = n
        var insertions = 0
        var deletions = 0
        var substitutions = 0
        while i > 0 || j > 0 {
            if i > 0, j > 0, hyp[i - 1] == ref[j - 1] {
                i -= 1
                j -= 1
            } else if i > 0, j > 0, dp[i][j] == dp[i - 1][j - 1] + 1 {
                substitutions += 1
                i -= 1
                j -= 1
            } else if i > 0, dp[i][j] == dp[i - 1][j] + 1 {
                insertions += 1
                i -= 1
            } else if j > 0, dp[i][j] == dp[i][j - 1] + 1 {
                deletions += 1
                j -= 1
            } else {
                break
            }
        }
        return (insertions, deletions, substitutions)
    }
}
