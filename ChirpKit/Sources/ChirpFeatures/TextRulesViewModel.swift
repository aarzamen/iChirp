import ChirpCore
import ChirpText
import Foundation
import Observation

/// Settings → Text → "Custom words & snippets" (M2): the person's list, add, edit, turn off, delete.
///
/// Custom words fix how Parakeet writes a word ("Kubernetes", a colleague's name); a replacement is optional (without
/// one the word only fixes capitalization). Snippets expand a spoken trigger into longer text. Both apply when Clean
/// runs: dictation's "Polish after", or the Clean clean-up mode for files. Every change is saved at once.
@MainActor @Observable public final class TextRulesViewModel {
    public private(set) var words: [CustomWord] = []
    public private(set) var snippets: [TextSnippet] = []
    /// The last failed change, in words (a duplicate, an empty field, a database error). Cleared by `dismissError()`.
    public private(set) var lastError: String?
    public private(set) var isLoaded = false

    @ObservationIgnored private let store: any TextRulesStoring
    @ObservationIgnored private let logger = Log.logger("text-rules")

    public init(store: any TextRulesStoring) {
        self.store = store
    }

    /// Words plus snippets, for the Settings row ("3").
    public var count: Int { words.count + snippets.count }

    public func load() async {
        do {
            words = try await store.customWords()
            snippets = try await store.snippets()
            isLoaded = true
        } catch {
            report(error)
        }
    }

    public func dismissError() {
        lastError = nil
    }

    // MARK: - Custom words

    /// Adds a word (and optional replacement). Returns false, with `lastError` set, when it is empty or a duplicate.
    @discardableResult
    public func addWord(_ word: String, replacement: String? = nil) async -> Bool {
        let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            lastError = "Type the word Parakeet should write."
            return false
        }
        return await save(CustomWord(word: trimmed, replacement: Self.nonBlank(replacement)))
    }

    /// Saves an edited word (its text, replacement or on/off switch).
    @discardableResult
    public func update(_ word: CustomWord) async -> Bool {
        var edited = word
        edited.word = word.word.trimmingCharacters(in: .whitespacesAndNewlines)
        edited.replacement = Self.nonBlank(word.replacement)
        edited.updatedAt = Date()
        guard !edited.word.isEmpty else {
            lastError = "Type the word Parakeet should write."
            return false
        }
        return await save(edited)
    }

    public func deleteWords(_ ids: Set<UUID>) async {
        do {
            try await store.deleteCustomWords(ids: ids)
            words.removeAll { ids.contains($0.id) }
        } catch {
            report(error)
        }
    }

    // MARK: - Snippets

    /// Adds a snippet. Returns false, with `lastError` set, when a field is empty or the trigger is a duplicate.
    @discardableResult
    public func addSnippet(trigger: String, expansion: String) async -> Bool {
        let trimmedTrigger = trigger.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedExpansion = expansion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTrigger.isEmpty, !trimmedExpansion.isEmpty else {
            lastError = "A snippet needs both what you say and what Parakeet writes."
            return false
        }
        return await save(TextSnippet(trigger: trimmedTrigger, expansion: trimmedExpansion))
    }

    @discardableResult
    public func update(_ snippet: TextSnippet) async -> Bool {
        var edited = snippet
        edited.trigger = snippet.trigger.trimmingCharacters(in: .whitespacesAndNewlines)
        edited.expansion = snippet.expansion.trimmingCharacters(in: .whitespacesAndNewlines)
        edited.updatedAt = Date()
        guard !edited.trigger.isEmpty, !edited.expansion.isEmpty else {
            lastError = "A snippet needs both what you say and what Parakeet writes."
            return false
        }
        return await save(edited)
    }

    public func deleteSnippets(_ ids: Set<UUID>) async {
        do {
            try await store.deleteSnippets(ids: ids)
            snippets.removeAll { ids.contains($0.id) }
        } catch {
            report(error)
        }
    }

    // MARK: - Helpers

    private func save(_ word: CustomWord) async -> Bool {
        do {
            try await store.save(word)
            words = try await store.customWords()
            return true
        } catch {
            report(error)
            return false
        }
    }

    private func save(_ snippet: TextSnippet) async -> Bool {
        do {
            try await store.save(snippet)
            snippets = try await store.snippets()
            return true
        } catch {
            report(error)
            return false
        }
    }

    private func report(_ error: any Error) {
        logger.error("text_rules_failed error_type=\(error.logTypeName, privacy: .public)")
        lastError = (error as? any LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    private static func nonBlank(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// Plan 022: the enabled words and snippets for a spoken instruction's final pass (Edit by voice).
    public func enabledRules() async -> DictationTextRules {
        await DictationTextRules.enabled(in: store)
    }
}

extension DictationTextRules {
    /// The enabled words and snippets from `store` (empty when it cannot be read: clean-up still runs).
    public static func enabled(in store: any TextRulesStoring) async -> DictationTextRules {
        let words = (try? await store.enabledCustomWords()) ?? []
        let snippets = (try? await store.enabledSnippets()) ?? []
        return DictationTextRules(customWords: words, snippets: snippets)
    }
}
