// New for iChirp (plan 025 Step A4). Upstream MacParakeet edits whole segments (TimedTranscriptTextEditSheet); iChirp
// corrects word spans, so the person's edited line is reduced to the smallest spans here.

import ChirpCore
import Foundation

/// Turns the person's edited text of one line into the smallest word-span corrections (plan 025 D1).
///
/// 1. The line's current text is split into display words, each mapped to the token it belongs to (a correction's
///    token may hold several words); the edited text is split on whitespace (line breaks count as spaces).
/// 2. A word diff (`CollectionDifference`, exact: case and punctuation count) groups the changes into hunks between
///    unchanged words.
/// 3. A pure insertion or deletion takes its neighbor word (the previous one; the next one at the start of the line),
///    so a span is never empty and the change stays visible.
/// 4. Each hunk is widened to whole tokens and mapped to engine word indexes; hunks that overlap or touch merge.
/// 5. A hunk whose new text equals the words as heard removes the corrections inside it (a revert by retyping);
///    otherwise it becomes one correction over its range, replacing those it covers.
///
/// Blank edited text throws `TranscriptCorrectionsError.emptyText`; no change returns an empty plan.
public enum CorrectionPlanner {
    public static func plan(
        line: TranscriptTextLine, tokens: [TranscriptToken], heard: (Range<Int>) -> String, editedText: String,
        origin: TranscriptCorrection.Origin, batchID: UUID? = nil, now: Date
    ) throws -> TranscriptCorrectionPlan {
        let edited = editedText.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !edited.isEmpty else { throw TranscriptCorrectionsError.emptyText }

        // 1. Display words, each with its token.
        var display: [String] = []
        var tokenOf: [Int] = []
        for index in line.tokenRange where tokens.indices.contains(index) {
            for piece in tokens[index].text.split(whereSeparator: \.isWhitespace) {
                display.append(String(piece))
                tokenOf.append(index)
            }
        }
        guard !display.isEmpty else { return TranscriptCorrectionPlan() }

        // 2. Which display word each unchanged edited word matches, and the hunks between them.
        var removed = Set<Int>()
        var inserted = Set<Int>()
        for change in edited.difference(from: display) {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var matched = [Int?](repeating: nil, count: display.count)
        var hunks: [Range<Int>] = []
        var displayIndex = 0
        var editedIndex = 0
        while displayIndex < display.count || editedIndex < edited.count {
            let displayStart = displayIndex
            let editedStart = editedIndex
            while displayIndex < display.count, removed.contains(displayIndex) { displayIndex += 1 }
            while editedIndex < edited.count, inserted.contains(editedIndex) { editedIndex += 1 }
            let removedAny = displayIndex > displayStart
            let insertedAny = editedIndex > editedStart
            if removedAny || insertedAny {
                var range = displayStart..<displayIndex
                if !removedAny || !insertedAny {
                    // 3. A pure insertion or deletion takes its neighbor: the previous word, or the next at the start.
                    range =
                        displayStart > 0
                        ? (displayStart - 1)..<displayIndex
                        : 0..<min(display.count, displayIndex + 1)
                }
                hunks.append(range)
            }
            guard displayIndex < display.count, editedIndex < edited.count else { break }
            matched[displayIndex] = editedIndex
            displayIndex += 1
            editedIndex += 1
        }
        guard !hunks.isEmpty else { return TranscriptCorrectionPlan() }

        // 4. Whole tokens, then merge hunks that overlap or touch.
        let firstWordOfToken = Dictionary(
            tokenOf.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { first, _ in first })
        let lastWordOfToken = Dictionary(
            tokenOf.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { _, last in last })
        var widened = hunks.map { hunk in
            firstWordOfToken[tokenOf[hunk.lowerBound]]!..<(lastWordOfToken[tokenOf[hunk.upperBound - 1]]! + 1)
        }
        widened.sort { $0.lowerBound < $1.lowerBound }
        var merged: [Range<Int>] = []
        for hunk in widened {
            if let last = merged.last, hunk.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, hunk.upperBound)
            } else {
                merged.append(hunk)
            }
        }

        // 5. One correction per hunk, or a revert when the new text is the words as heard.
        var plan = TranscriptCorrectionPlan()
        for hunk in merged {
            // The words just outside a merged hunk are unchanged, so they have edited counterparts.
            let editedStart = hunk.lowerBound == 0 ? 0 : (matched[hunk.lowerBound - 1] ?? -1) + 1
            let editedEnd = hunk.upperBound == display.count ? edited.count : (matched[hunk.upperBound] ?? edited.count)
            let text = edited[editedStart..<max(editedStart, editedEnd)].joined(separator: " ")
            let firstToken = tokens[tokenOf[hunk.lowerBound]]
            let lastToken = tokens[tokenOf[hunk.upperBound - 1]]
            let wordRange = firstToken.wordRange.lowerBound..<lastToken.wordRange.upperBound
            let covered = Set(tokens[tokenOf[hunk.lowerBound]...tokenOf[hunk.upperBound - 1]].compactMap(\.editID))
            plan.remove.formUnion(covered)
            guard !text.isEmpty, text != heard(wordRange) else { continue }
            plan.add.append(
                TranscriptCorrection(
                    wordRange: wordRange, heard: heard(wordRange), text: text, origin: origin, batchID: batchID,
                    createdAt: now, updatedAt: now))
        }
        return plan
    }
}
