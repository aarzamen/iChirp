import ChirpCore
import ChirpText
import ChirpUI
import Foundation
import SwiftUI

/// A transcript line as the screen draws it (plan 025 D5): the text, with a dotted underline in `secondary` under
/// every corrected passage; Part B adds the Find fills (`findMatchFill` behind every match, `findCurrentFill` behind the
/// current one; a correction's underline inside a match is drawn in `ink`, which is glyph-safe on both fills). Nothing
/// else is styled. Pure, so `TranscriptCorrectionsAppTests` and `TranscriptFindAppTests` check it without a view.
enum TranscriptLineText {
    /// The Find matches on one line: UTF-16 ranges of `line.text`, and the current match when it is on this line.
    struct FindMarks: Equatable {
        var matches: [NSRange]
        var current: NSRange?
    }

    static func attributed(_ line: TranscriptTextLine, tokens: [TranscriptToken], find: FindMarks? = nil)
        -> AttributedString
    {
        var text = AttributedString(line.text)
        let utf16 = line.text.utf16
        func textRange(_ lowerBound: Int, _ upperBound: Int) -> Range<AttributedString.Index>? {
            guard lowerBound >= 0, upperBound <= utf16.count, lowerBound < upperBound,
                let lower = utf16.index(utf16.startIndex, offsetBy: lowerBound, limitedBy: utf16.endIndex),
                let upper = utf16.index(utf16.startIndex, offsetBy: upperBound, limitedBy: utf16.endIndex),
                let start = AttributedString.Index(lower, within: text),
                let end = AttributedString.Index(upper, within: text)
            else { return nil }
            return start..<end
        }
        let corrected = correctedRanges(line, tokens: tokens)
        for utf16Range in corrected {
            guard let range = textRange(utf16Range.lowerBound, utf16Range.upperBound) else { continue }
            text[range].underlineStyle = Text.LineStyle(pattern: .dot, color: Tokens.Color.secondary)
        }
        guard let find else { return text }
        for match in find.matches {
            guard let range = textRange(match.location, match.location + match.length) else { continue }
            text[range].backgroundColor =
                match == find.current ? Tokens.Color.findCurrentFill : Tokens.Color.findMatchFill
            // A correction's underline inside a match: ink, glyph-safe on both fills.
            for utf16Range in corrected {
                let lower = max(utf16Range.lowerBound, match.location)
                let upper = min(utf16Range.upperBound, match.location + match.length)
                guard lower < upper, let overlap = textRange(lower, upper) else { continue }
                text[overlap].underlineStyle = Text.LineStyle(pattern: .dot, color: Tokens.Color.ink)
            }
        }
        return text
    }

    /// How many corrections the line shows.
    static func correctionCount(in line: TranscriptTextLine, tokens: [TranscriptToken]) -> Int {
        correctedRanges(line, tokens: tokens).count
    }

    /// The UTF-16 range of each corrected token in `line.text` (empty for a line whose text is not its tokens).
    private static func correctedRanges(_ line: TranscriptTextLine, tokens: [TranscriptToken]) -> [Range<Int>] {
        guard line.tokenUTF16Ranges.count == line.tokenRange.count else { return [] }
        return zip(line.tokenRange, line.tokenUTF16Ranges).compactMap { index, range in
            tokens.indices.contains(index) && tokens[index].editID != nil ? range : nil
        }
    }
}

/// The words of the correction sheets and menus (plan 025 D5).
enum TranscriptCorrectionsCopy {
    /// More → "Corrections (N)…", shown while there are corrections, or ones kept from an earlier transcript.
    static func menuTitle(applied: Int, detached: Int) -> String? {
        applied + detached > 0 ? "Corrections (\(applied))…" : nil
    }

    static func revertAllTitle(count: Int) -> String {
        count == 1 ? "Revert the correction?" : "Revert all \(count) corrections?"
    }

    /// The dialog's destructive button: "Revert" for one correction (the title says "the correction"), else "Revert All".
    static func revertAllButton(count: Int) -> String {
        count == 1 ? "Revert" : "Revert All"
    }

    static let revertAllMessage =
        "The transcript goes back to the words Parakeet heard. Documents already made from it don’t change."

    /// The Corrections sheet's footer.
    static let documentsFooter = "Documents made earlier keep their text. Transform again to use your corrections."

    /// The Correct passage sheet's footer.
    static let correctFooter =
        "Fix words Parakeet misheard. The words as heard are kept: Show Original brings them back."

    static let saveFailed = "Couldn’t save. Your text is still here."

    /// Where a correction came from, as its row says it.
    static func originTitle(_ origin: TranscriptCorrection.Origin, batchCount: Int) -> String {
        switch origin {
        case .edit: "Corrected"
        case .replace: "Replaced"
        case .replaceAll: "Replace all · \(batchCount)"
        case .rule: "Rule"
        case .voiceCommand: "Voice command"
        }
    }

    /// "Speaker 1 · 04:12 – 04:31" above the passage being corrected.
    static func passageLine(speaker: String?, startMs: Int, endMs: Int) -> String {
        let times = "\(Formatting.clock(ms: startMs)) – \(Formatting.clock(ms: endMs))"
        guard let speaker, !speaker.isEmpty else { return times }
        return "\(speaker) · \(times)"
    }
}

/// "Made before your corrections" on a document listed under Made from this (plan 025 D5).
enum MadeBeforeCorrections {
    static func applies(documentCreatedAt: Date, correctionsChangedAt: Date?) -> Bool {
        guard let correctionsChangedAt else { return false }
        return documentCreatedAt < correctionsChangedAt
    }
}
