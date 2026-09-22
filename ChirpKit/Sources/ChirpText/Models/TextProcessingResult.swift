// Ported from MacParakeet (GPL-3.0): Sources/MacParakeetCore/TextProcessing/TextProcessingResult.swift @ bbae9e0e
// Changes: none — direct port, no upstream types referenced besides KeyAction (ported alongside it).

import Foundation

public struct TextProcessingResult: Sendable {
    public let text: String
    public let expandedSnippetIDs: Set<UUID>
    public let postPasteAction: KeyAction?

    public init(
        text: String,
        expandedSnippetIDs: Set<UUID> = [],
        postPasteAction: KeyAction? = nil
    ) {
        self.text = text
        self.expandedSnippetIDs = expandedSnippetIDs
        self.postPasteAction = postPasteAction
    }
}
