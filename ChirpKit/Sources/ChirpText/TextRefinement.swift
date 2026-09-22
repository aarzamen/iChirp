// Ported from MacParakeet (GPL-3.0): Sources/MacParakeetCore/TextProcessing/TextRefinementService.swift @ bbae9e0e
// Changes: collapsed to the M0/M1 surface pinned by the implementation plan — synchronous,
// `Dictation.ProcessingMode` replaced by ChirpCore's `CleanupMode`, and the result is a plain
// `String?` (nil for `.raw`) instead of a `TextRefinementResult` carrying `path`/`postPasteAction`;
// raw-mode trailing-action extraction and `insertionStyle` routing were not carried over — see
// ChirpText's README for what that drops from the upstream service's test coverage.

import ChirpCore
import Foundation

/// Applies the deterministic text-processing pipeline when the transcript's cleanup mode calls for it.
public struct TextRefinement: Sendable {
    public init() {}

    /// Returns the deterministically cleaned text for `.clean`, or `nil` for `.raw` (no processing
    /// applied — callers display the raw transcript as-is).
    public func refine(
        rawText: String,
        mode: CleanupMode,
        customWords: [CustomWord],
        snippets: [TextSnippet],
        removeUmFiller: Bool = true
    ) -> String? {
        guard mode == .clean else { return nil }

        return TextProcessingPipeline().process(
            text: rawText,
            customWords: customWords,
            snippets: snippets,
            removeUmFiller: removeUmFiller
        ).text
    }
}
