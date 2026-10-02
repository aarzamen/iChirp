// New for iChirp (review R5-2; plan 025 ruling 2, option R5-a): a dictation's applied voice commands, stored as word
// corrections so every view of the transcript reads what was copied.

import ChirpCore
import Foundation

/// Turns a dictation's voice commands into `voiceCommand` corrections of its words.
///
/// The commands ran on the final pass's text (`commandedText`: the clean text when Clean or Polish after ran, else the
/// engine's text) and produced `resultText`, the text that was copied. Two alignments find what changed and where it
/// sits in the engine's words:
/// - the commanded text's pieces against the heard words (a word diff, case and edge punctuation ignored, as
///   `CleanTextAligner` does: clean-up dropped fillers and swapped custom words, the rest matches);
/// - the result's pieces against the commanded text's (exact, the line breaks before a piece included: "new
///   paragraph").
///
/// A commanded piece matched on both sides is a stable point. Between two stable points where the result differs from
/// the commanded text, the heard words between them become one correction whose text is the result's pieces there,
/// with their line breaks. A correction never has empty text and never starts with a line break, so a pure deletion
/// (a scratched sentence) or a break takes the stable word before it (the one after, at the start). A plan that still
/// breaks an invariant falls back to one correction over every word with the whole result. No change other than
/// spacing plans nothing (an empty plan); nil means the change cannot be stored as corrections (no words, an empty
/// result, or not even the fallback keeps the invariants), so the caller must not treat the stored text as commanded.
public enum VoiceCommandCorrections {
    /// A region between stable points: open interval `(left, right)` of stable indexes; -1 and `stable.count` stand
    /// for the start and the end of the text.
    private struct Region {
        var left: Int
        var right: Int
    }

    private struct Stable {
        var commanded: Int
        var word: Int
        var result: Int
    }

    /// Plan 025 B4: the same over a row's word stream (`TranscriptTokens.of`), for a dictation whose learned-rule
    /// corrections were stored before its commands ran. Each token counts as one word; each planned span is then mapped
    /// to the engine words its tokens cover, so it covers whole corrections and replaces the ones it touches. Without
    /// corrections the tokens are the words and the plan is the words' plan.
    public static func plan(
        tokens: [TranscriptToken], commandedText: String, resultText: String, batchID: UUID, now: Date
    ) -> TranscriptCorrectionPlan? {
        let words = TranscriptTokens.words(of: tokens, engine: [])
        guard
            var plan = plan(
                words: words, commandedText: commandedText, resultText: resultText, batchID: batchID, now: now)
        else { return nil }
        plan.add = plan.add.map { add in
            var mapped = add
            let range = add.range
            mapped.wordRange = TranscriptSegmentWordRange(
                startIndex: tokens[range.lowerBound].wordRange.lowerBound,
                endIndexExclusive: tokens[range.upperBound - 1].wordRange.upperBound)
            return mapped
        }
        return plan
    }

    public static func plan(
        words: [WordTimestamp], commandedText: String, resultText: String, batchID: UUID, now: Date
    ) -> TranscriptCorrectionPlan? {
        let result = pieces(resultText)
        let commanded = pieces(commandedText)
        guard commanded != result else { return TranscriptCorrectionPlan() }
        guard !words.isEmpty, !result.isEmpty else { return nil }

        // The heard side: every whitespace-separated piece of every word, with its word.
        var heard: [String] = []
        var heardWord: [Int] = []
        for (index, word) in words.enumerated() {
            for piece in word.word.split(whereSeparator: \.isWhitespace) {
                heard.append(normalized(piece))
                heardWord.append(index)
            }
        }
        let toHeard = matches(from: commanded.map { normalized(Substring($0.text)) }, to: heard)
        let toResult = matches(from: commanded, to: result)
        var stable: [Stable] = []
        for index in commanded.indices {
            guard let heardIndex = toHeard[index], let resultIndex = toResult[index] else { continue }
            let word = heardWord[heardIndex]
            if let last = stable.last, word <= last.word || resultIndex <= last.result { continue }
            stable.append(Stable(commanded: index, word: word, result: resultIndex))
        }

        func range(_ region: Region, _ value: (Stable) -> Int, count: Int) -> Range<Int> {
            let lower = region.left < 0 ? 0 : value(stable[region.left]) + 1
            let upper = region.right >= stable.count ? count : value(stable[region.right])
            return lower..<max(lower, upper)
        }
        func wordRange(_ region: Region) -> Range<Int> { range(region, \.word, count: words.count) }
        func resultRange(_ region: Region) -> Range<Int> { range(region, \.result, count: result.count) }
        func commandedRange(_ region: Region) -> Range<Int> { range(region, \.commanded, count: commanded.count) }
        func text(_ range: Range<Int>) -> String {
            var text = ""
            for index in range {
                if index > range.lowerBound {
                    text += result[index].breaks > 0 ? String(repeating: "\n", count: result[index].breaks) : " "
                }
                text += result[index].text
            }
            return text
        }
        func isValid(_ region: Region) -> Bool {
            let resultPart = resultRange(region)
            guard !wordRange(region).isEmpty, !resultPart.isEmpty else { return false }
            return region.left < 0 || result[resultPart.lowerBound].breaks == 0
        }

        // The regions where the result differs from the commanded text.
        var regions: [Region] = []
        for left in -1..<stable.count {
            let region = Region(left: left, right: left + 1)
            if Array(result[resultRange(region)]) != Array(commanded[commandedRange(region)]) {
                regions.append(region)
            }
        }
        guard !regions.isEmpty else { return TranscriptCorrectionPlan() }

        // Grow each invalid region over its neighbor stable point, merging regions that come to overlap.
        var grew = true
        while grew {
            grew = false
            for index in regions.indices where !isValid(regions[index]) {
                if regions[index].left >= 0 {
                    regions[index].left -= 1
                    grew = true
                } else if regions[index].right < stable.count {
                    regions[index].right += 1
                    grew = true
                }
            }
            var merged: [Region] = []
            for region in regions.sorted(by: { $0.left < $1.left }) {
                if let last = merged.last, region.left < last.right {
                    merged[merged.count - 1].right = max(last.right, region.right)
                } else {
                    merged.append(region)
                }
            }
            regions = merged
        }

        var plan = TranscriptCorrectionPlan()
        for region in regions {
            let words = wordRange(region)
            plan.add.append(
                TranscriptCorrection(
                    wordRange: words, heard: "", text: text(resultRange(region)), origin: .voiceCommand,
                    batchID: batchID, createdAt: now, updatedAt: now))
        }
        if regions.allSatisfy(isValid), (try? TranscriptCorrections.empty.applying(plan, words: words, now: now)) != nil
        {
            return plan
        }
        // Fallback: one correction over every word with the whole result.
        let whole = TranscriptCorrectionPlan(add: [
            TranscriptCorrection(
                wordRange: 0..<words.count, heard: "", text: text(0..<result.count), origin: .voiceCommand,
                batchID: batchID, createdAt: now, updatedAt: now)
        ])
        return (try? TranscriptCorrections.empty.applying(whole, words: words, now: now)) == nil ? nil : whole
    }

    // MARK: - Pieces

    /// A whitespace-separated piece of text and the number of line breaks in the whitespace before it (0 for the
    /// first piece).
    struct Piece: Equatable {
        var text: String
        var breaks: Int
    }

    static func pieces(_ text: String) -> [Piece] {
        var result: [Piece] = []
        var current = ""
        var breaks = 0
        for character in text {
            if character.isWhitespace {
                if !current.isEmpty {
                    result.append(Piece(text: current, breaks: result.isEmpty ? 0 : breaks))
                    current = ""
                    breaks = 0
                }
                if character.isNewline { breaks += 1 }
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { result.append(Piece(text: current, breaks: result.isEmpty ? 0 : breaks)) }
        return result
    }

    /// For each element of `from`, the index of the element of `to` it matches in a longest common subsequence.
    static func matches<Element: Equatable>(from: [Element], to: [Element]) -> [Int?] {
        var removed = Set<Int>()
        var inserted = Set<Int>()
        for change in to.difference(from: from) {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var result = [Int?](repeating: nil, count: from.count)
        var target = 0
        for index in from.indices where !removed.contains(index) {
            while inserted.contains(target) { target += 1 }
            result[index] = target
            target += 1
        }
        return result
    }

    /// Lowercased, without punctuation at either end; a piece of punctuation only stays as is.
    private static func normalized(_ piece: Substring) -> String {
        let trimmed = piece.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        return (trimmed.isEmpty ? String(piece) : trimmed).lowercased()
    }
}
