// Ported from MacParakeet (GPL-3.0): Sources/MacParakeetViewModels/TranscriptFindModel.swift @ bbae9e0e
// Changes: matching moved to ChirpText.TranscriptSearchIndex (built once per `setBlocks`, plan 025 D4); `Match` is
// `TranscriptFindMatch`; adds `hasQueryButNoMatches`, the counter text and the VoiceOver announcement text.

import ChirpText
import Foundation
import Observation

/// Pure, testable state of the Transcript screen's find bar (plan 025 Part B).
///
/// The model knows nothing about SwiftUI or how the transcript is drawn. It searches an ordered list of text *blocks*
/// (the screen's lines, in order) and keeps one globally ordered match list and a cursor. The screen maps a match's
/// `blockIndex` back to a line (scroll target, highlight). Match positions are UTF-16 `NSRange`s in the block's text,
/// which bridge to `AttributedString` highlighting.
@MainActor
@Observable
public final class TranscriptFindModel {
    public typealias Match = TranscriptFindMatch

    /// Current search query. Mutate through `setQuery` so matches recompute.
    public private(set) var query: String = ""

    /// All matches across all blocks, in reading order (block order, then position within each block).
    public private(set) var matches: [Match] = []

    /// Index into `matches` of the emphasized ("current") match, or `nil` when there are no matches.
    public private(set) var currentMatchIndex: Int?

    @ObservationIgnored private var index = TranscriptSearchIndex(blocks: [])
    /// The match count last announced to VoiceOver for the current query (`takeCountAnnouncement()`).
    @ObservationIgnored private var announcedCount: Int?

    public init() {}

    // MARK: - Mutation

    /// Update the query and recompute matches. Resets the cursor to the first match. A trimmed-empty query clears all
    /// matches.
    public func setQuery(_ newValue: String) {
        guard newValue != query else { return }
        query = newValue
        if !hasSearchableQuery { announcedCount = nil }
        recompute()
    }

    /// Replace the searched content and re-run the current query against it. Used when the reading surface changes (a
    /// new transcript loads, a correction or a Replace lands) so the live find session stays in sync. Keeps the current
    /// match when the same block/range still exists, otherwise keeps the same ordinal where possible instead of jumping
    /// back to the start.
    public func setBlocks(_ blocks: [String]) {
        let previousCurrent = current
        let previousIndex = currentMatchIndex
        index = TranscriptSearchIndex(blocks: blocks)
        recompute(preserving: previousCurrent, preferredIndex: previousIndex)
    }

    /// Clear the query and all matches.
    public func clear() {
        setQuery("")
    }

    /// Advance the cursor to the next match, wrapping at the end.
    public func next() {
        guard !matches.isEmpty else { return }
        let i = currentMatchIndex ?? -1
        currentMatchIndex = (i + 1) % matches.count
    }

    /// Move the cursor to the previous match, wrapping at the start.
    public func prev() {
        guard !matches.isEmpty else { return }
        let i = currentMatchIndex ?? 0
        currentMatchIndex = (i - 1 + matches.count) % matches.count
    }

    // MARK: - Derived state

    public var matchCount: Int { matches.count }
    public var hasMatches: Bool { !matches.isEmpty }

    /// A query to search for (not blank) that found nothing: the bar says "No matches".
    public var hasQueryButNoMatches: Bool { hasSearchableQuery && matches.isEmpty }

    /// The emphasized match, or `nil` when there are none.
    public var current: Match? {
        guard let i = currentMatchIndex, matches.indices.contains(i) else { return nil }
        return matches[i]
    }

    /// 1-based "current of total" position for the counter, or `nil` when there are no matches.
    public var displayPosition: (current: Int, total: Int)? {
        guard let i = currentMatchIndex, matches.indices.contains(i) else { return nil }
        return (i + 1, matches.count)
    }

    /// The bar's counter: "3 of 12", "No matches", or nothing while the query is blank.
    public var counterText: String {
        if let position = displayPosition { return "\(position.current) of \(position.total)" }
        return hasSearchableQuery ? "No matches" : ""
    }

    /// What VoiceOver says after Next or Previous: "3 of 12, at 12:04" (the time of the current match, when the
    /// transcript has timings). Nil without a current match. Positions and times only, never transcript text.
    public func positionAnnouncement(timeMs: Int?) -> String? {
        guard let position = displayPosition else { return nil }
        let base = "\(position.current) of \(position.total)"
        guard let timeMs else { return base }
        return base + ", at " + TranscriptPromptFormatter.timestamp(milliseconds: timeMs)
    }

    /// What VoiceOver says after typing: "12 matches", "1 match" or "No matches", only when the count differs from the
    /// last one said for this search (so typing does not repeat it); nil otherwise or while the query is blank.
    public func takeCountAnnouncement() -> String? {
        guard hasSearchableQuery, announcedCount != matches.count else { return nil }
        announcedCount = matches.count
        return Self.countText(matches.count)
    }

    /// "12 matches", "1 match", "No matches".
    public static func countText(_ count: Int) -> String {
        switch count {
        case 0: "No matches"
        case 1: "1 match"
        default: "\(count) matches"
        }
    }

    private var hasSearchableQuery: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Matching

    private func recompute(preserving previousCurrent: Match? = nil, preferredIndex: Int? = nil) {
        // Blank queries match nothing; the untrimmed query is searched (`TranscriptSearchIndex`), so " the " finds the
        // word, not the "the" inside "there" or "other".
        let result = index.matches(for: query)
        matches = result
        guard !result.isEmpty else {
            currentMatchIndex = nil
            return
        }
        if let previousCurrent,
            let retainedIndex = result.firstIndex(of: previousCurrent)
        {
            currentMatchIndex = retainedIndex
        } else if let preferredIndex {
            currentMatchIndex = min(max(preferredIndex, 0), result.count - 1)
        } else {
            currentMatchIndex = 0
        }
    }
}
