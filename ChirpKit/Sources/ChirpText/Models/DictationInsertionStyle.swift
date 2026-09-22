// Ported from MacParakeet (GPL-3.0): Sources/MacParakeetCore/AppRuntimePreferences.swift @ bbae9e0e
// Changes: extracted the standalone `DictationInsertionStyle` enum into its own ChirpText model file;
// no other adaptations.

import Foundation

public enum DictationInsertionStyle: String, CaseIterable, Hashable, Sendable, Equatable {
    case sentence
    case inline

    public var displayTitle: String {
        switch self {
        case .sentence:
            return "Sentence"
        case .inline:
            return "Inline"
        }
    }

    public var detail: String {
        switch self {
        case .sentence:
            return "Starts like a sentence and keeps ending punctuation."
        case .inline:
            return "Fits replacements, fields, search, and commands."
        }
    }

    public var previewText: String {
        switch self {
        case .sentence:
            return "Hello world."
        case .inline:
            return "hello world"
        }
    }
}
