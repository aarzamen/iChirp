import ChirpCore
import ChirpText
import ChirpUI
import SwiftUI

/// A transcript line as the screen draws it (plan 025 D5): the text, with a dotted underline in `secondary` under
/// every corrected passage and no other styling. Pure, so `TranscriptCorrectionsAppTests` checks it without a view.
enum TranscriptLineText {
    static func attributed(_ line: TranscriptTextLine, tokens: [TranscriptToken]) -> AttributedString {
        var text = AttributedString(line.text)
        let utf16 = line.text.utf16
        for range in correctedRanges(line, tokens: tokens) {
            guard range.lowerBound >= 0, range.upperBound <= utf16.count,
                let lower = utf16.index(utf16.startIndex, offsetBy: range.lowerBound, limitedBy: utf16.endIndex),
                let upper = utf16.index(utf16.startIndex, offsetBy: range.upperBound, limitedBy: utf16.endIndex),
                let start = AttributedString.Index(lower, within: text),
                let end = AttributedString.Index(upper, within: text)
            else { continue }
            text[start..<end].underlineStyle = Text.LineStyle(pattern: .dot, color: Tokens.Color.secondary)
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
