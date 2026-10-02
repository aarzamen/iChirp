import Foundation

/// Persistence for the person's custom words and snippets (M2). ChirpStore implements it on GRDB
/// (`GRDBTextRulesStore`); view models and pipelines see only this protocol.
///
/// Words are unique by `word` and snippets by `trigger`, case-insensitively (upstream's `COLLATE NOCASE` indexes): a
/// save that would duplicate one throws `TextRulesStoreError.duplicate`. Lists come back sorted case-insensitively.
public protocol TextRulesStoring: Sendable {
    func customWords() async throws -> [CustomWord]
    /// Inserts a new word or replaces the one with the same id.
    func save(_ word: CustomWord) async throws
    func deleteCustomWords(ids: Set<UUID>) async throws
    func snippets() async throws -> [TextSnippet]
    /// Inserts a new snippet or replaces the one with the same id.
    func save(_ snippet: TextSnippet) async throws
    func deleteSnippets(ids: Set<UUID>) async throws
}

extension TextRulesStoring {
    /// The enabled words, in order, for `TextRefinement` / `TextProcessingPipeline`.
    public func enabledCustomWords() async throws -> [CustomWord] {
        try await customWords().filter(\.isEnabled)
    }

    /// Plan 025 D8: the enabled words the person typed (`source == .manual`), the only ones Clean and the meeting
    /// applier use. Learned rules act only as corrections.
    public func enabledManualCustomWords() async throws -> [CustomWord] {
        try await customWords().filter { $0.isEnabled && $0.source == .manual }
    }

    /// Plan 025 D8: the enabled learned rules ("Also fix future transcripts"), applied to new transcripts as
    /// corrections (`LearnedRuleMatcher`).
    public func enabledLearnedRules() async throws -> [CustomWord] {
        try await customWords().filter { $0.isEnabled && $0.source == .learned }
    }

    /// The enabled snippets.
    public func enabledSnippets() async throws -> [TextSnippet] {
        try await snippets().filter(\.isEnabled)
    }
}

public enum TextRulesStoreError: Error, Equatable, LocalizedError {
    /// Another word (or snippet trigger) already has this text, ignoring case.
    case duplicate(String)

    public var errorDescription: String? {
        switch self {
        case .duplicate(let text): "“\(text)” is already in your list."
        }
    }
}
