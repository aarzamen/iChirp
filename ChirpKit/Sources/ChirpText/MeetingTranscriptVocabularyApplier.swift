// Ported from MacParakeet (GPL-3.0): Sources/MacParakeetCore/Services/MeetingRecording/MeetingTranscriptVocabularyApplier.swift @ bbae9e0e
// Changes: public entry point for ChirpFeatures' meeting finalizer; otherwise a direct port.

import ChirpCore
import Foundation

/// Applies the person's custom-word corrections to a finalized meeting transcript: the plain text and each word token.
///
/// Meetings run only this step of the dictation pipeline (upstream rule): no filler removal, snippets or insertion
/// styling, which would corrupt a verbatim meeting record. Timings, confidence and speaker ids stay exactly as they
/// were; corrections are spelling-only. A multi-token rule ("mac parakeet" → "MacParakeet") rewrites the text, but the
/// per-word pass corrects tokens one at a time, so such a phrase is corrected in the text only.
public enum MeetingTranscriptVocabularyApplier {
    private static let tokenWordCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))
    private static let tokenTrimCharacters = tokenWordCharacters.inverted

    public static func apply(
        rawTranscript: String, words: [WordTimestamp], customWords: [CustomWord]
    ) -> (rawTranscript: String, words: [WordTimestamp]) {
        let replacer = CustomWordReplacer(words: customWords)
        guard !replacer.isEmpty else { return (rawTranscript, words) }
        let correctedTranscript = replacer.apply(to: rawTranscript)
        let tokenLookup = tokenVocabularyLookup(from: customWords)
        let correctedWords = words.map { word -> WordTimestamp in
            guard shouldScanToken(word.word, tokenLookup: tokenLookup) else { return word }
            var corrected = word
            corrected.word = replacer.apply(to: word.word)
            return corrected
        }
        return (correctedTranscript, correctedWords)
    }

    /// Lower-cased keys of the enabled words, or nil when a word has no letters or digits (then every token is
    /// scanned).
    private static func tokenVocabularyLookup(from customWords: [CustomWord]) -> Set<String>? {
        var keys: Set<String> = []
        for customWord in customWords where customWord.isEnabled {
            guard let key = tokenLookupKey(for: customWord.word) else { return nil }
            keys.insert(key)
        }
        return keys
    }

    private static func shouldScanToken(_ text: String, tokenLookup: Set<String>?) -> Bool {
        guard let tokenLookup else { return true }
        guard !tokenLookup.isEmpty else { return false }
        return !tokenCandidateKeys(for: text).isDisjoint(with: tokenLookup)
    }

    private static func tokenCandidateKeys(for text: String) -> Set<String> {
        guard let key = tokenLookupKey(for: text) else { return [] }
        var keys: Set<String> = [key]
        for component in key.split(whereSeparator: { !isTokenWordCharacter($0) }) {
            keys.insert(String(component))
        }
        return keys
    }

    private static func tokenLookupKey(for text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: tokenTrimCharacters)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.lowercased()
    }

    private static func isTokenWordCharacter(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { tokenWordCharacters.contains($0) }
    }
}
