// Semantics from MacParakeet (GPL-3.0): Sources/MacParakeetViewModels/PromptsViewModel.swift @ bbae9e0e — addPrompt
// (name and content required) and isUniqueName (names unique ignoring case); and
// Sources/MacParakeetCore/Database/PromptEditingService.swift @ bbae9e0e — uniqueRestoredName. Fresh implementation,
// not a line port.

import Foundation

/// What the person typed for a template of their own (plan 026): the editor checks it as they type, and the store checks
/// it again inside the save transaction. Contract: spec/contracts/deliverables-v1.md "Template library".
public struct TemplateDraft: Sendable, Equatable {
    /// Why a draft cannot be saved; `sentence` is what the editor shows.
    public enum Problem: Error, Equatable, Sendable {
        case emptyName
        case nameTooLong
        /// The name of the template that already has it, as that template spells it.
        case duplicateName(String)
        case emptyInstructions
        case instructionsTooLong(count: Int)
        /// The tag, written as `<name>` in lower case.
        case reservedTag(String)

        public var sentence: String {
            switch self {
            case .emptyName:
                "Give the template a name."
            case .nameTooLong:
                "A name can be up to \(TemplateLimits.maxNameLength) characters."
            case .duplicateName(let name):
                "“\(name)” is already a template. Choose another name."
            case .emptyInstructions:
                "Write the instructions first."
            case .instructionsTooLong(let count):
                "Instructions can be up to \(TemplateLimits.formatted(TemplateLimits.maxInstructionCharacters)) "
                    + "characters; these are \(TemplateLimits.formatted(count)). Shorter instructions leave more room "
                    + "for the transcript."
            case .reservedTag(let tag):
                "Remove “\(tag)” from the instructions: Parakeet uses it to mark the transcript and your notes."
            }
        }
    }

    public var name: String
    /// Which section it lives in and what it makes: `.deliverable` = a document, `.transform` = a rewrite.
    public var category: PromptTemplate.Category
    public var instructions: String
    /// The raise-only switch: on means what it makes is clinical (as SOAP note's output is); off means no raise.
    public var makesClinicalDocuments: Bool

    public init(
        name: String,
        category: PromptTemplate.Category,
        instructions: String,
        makesClinicalDocuments: Bool
    ) {
        self.name = name
        self.category = category
        self.instructions = instructions
        self.makesClinicalDocuments = makesClinicalDocuments
    }

    /// A draft holding a template's name, kind and switch, with `instructions` (its version's text).
    public init(template: PromptTemplate, instructions: String) {
        self.init(
            name: template.name,
            category: template.category,
            instructions: instructions,
            makesClinicalDocuments: template.outputPrivacyClass == .clinical)
    }

    /// One line: line breaks become spaces, runs of spaces collapse, the ends are trimmed.
    public var cleanedName: String {
        name.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// The instructions with blank space trimmed from both ends (the inside is the person's and stays as written).
    public var cleanedInstructions: String {
        instructions.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Characters of the cleaned instructions (what the limit counts).
    public var characterCount: Int { cleanedInstructions.count }

    /// `.clinical` when the switch is on, else nil: a template can raise its output, never lower anything.
    public var outputPrivacyClass: PrivacyClass? { makesClinicalDocuments ? .clinical : nil }

    /// The first problem, or nil when the draft can be saved. `takenNames` are the names of the other templates that
    /// are not deleted (hidden ones included); leave the template's own name out when editing it.
    public func problem(takenNames: [String]) -> Problem? {
        let name = cleanedName
        if name.isEmpty { return .emptyName }
        if name.count > TemplateLimits.maxNameLength { return .nameTooLong }
        if let taken = takenNames.first(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
            return .duplicateName(taken)
        }
        let instructions = cleanedInstructions
        if instructions.isEmpty { return .emptyInstructions }
        if instructions.count > TemplateLimits.maxInstructionCharacters {
            return .instructionsTooLong(count: instructions.count)
        }
        if let tag = TemplateLimits.reservedTag(in: instructions) { return .reservedTag(tag) }
        return nil
    }
}

/// Limits and the reserved tags for templates of your own.
public enum TemplateLimits {
    public static let maxNameLength = 40
    /// About four times the longest built-in. On Apple's 4K-token window a template this long still leaves more than
    /// 3,000 characters of transcript per call (pinned by `UserTemplatePromptTests`).
    public static let maxInstructionCharacters = 4_000
    /// The tags Parakeet wraps the source in (`MapReduceGenerator`); a person's instructions may not open or close them.
    /// Longer names first so `transcript_part` is reported as itself.
    public static let reservedTagNames = [
        "transcript_part", "transcript_notes", "transcript", "user_notes", "task", "document",
    ]

    /// `<` or `</`, a reserved name, then anything but a letter, digit or underscore (or the end): `<tasks>` and
    /// `<b>` stay allowed. The pattern is a constant, so compiling it cannot fail.
    private static let reservedOpener = try! NSRegularExpression(
        pattern: "<(/?)(\(reservedTagNames.joined(separator: "|")))(?![A-Za-z0-9_])", options: [.caseInsensitive])

    /// The first reserved tag in `text`, as `<name>` in lower case; nil when there is none.
    public static func reservedTag(in text: String) -> String? {
        let range = NSRange(text.startIndex..., in: text)
        guard let match = reservedOpener.firstMatch(in: text, range: range),
            let nameRange = Range(match.range(at: 2), in: text)
        else { return nil }
        return "<\(text[nameRange].lowercased())>"
    }

    /// Defense in depth for text that reached the database before the rule (or by another path): every reserved
    /// opener's `<` becomes `‹`, so the model cannot read it as one of Parakeet's source tags. Other text is unchanged.
    public static func neutralizingReservedTags(in text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        return reservedOpener.stringByReplacingMatches(in: text, range: range, withTemplate: "‹$1$2")
    }

    /// "4,312": grouped digits, the same on every device (the sentences are English).
    static func formatted(_ count: Int) -> String {
        count.formatted(.number.grouping(.automatic).locale(Locale(identifier: "en_US")))
    }
}

/// Free names for copies and restored templates; every result fits `TemplateLimits.maxNameLength`.
public enum TemplateNaming {
    /// "SOAP note copy", then "SOAP note copy 2", 3, … — the first not in `taken` (ignoring case).
    public static func copyName(of name: String, taken: [String]) -> String {
        firstFree(base: name, taken: taken) { $0 == 1 ? " copy" : " copy \($0)" }
    }

    /// The name itself when it is free; else "Clinic SOAP (restored)", then "(restored 2)", …
    public static func restoredName(of name: String, taken: [String]) -> String {
        if !isTaken(name, in: taken) { return name }
        return firstFree(base: name, taken: taken) { $0 == 1 ? " (restored)" : " (restored \($0))" }
    }

    private static func firstFree(base: String, taken: [String], suffix: (Int) -> String) -> String {
        var number = 1
        while true {
            let ending = suffix(number)
            let room = max(0, TemplateLimits.maxNameLength - ending.count)
            let trimmed = String(base.prefix(room)).trimmingCharacters(in: .whitespaces)
            let candidate = trimmed + ending
            if !isTaken(candidate, in: taken) { return candidate }
            number += 1
        }
    }

    private static func isTaken(_ name: String, in taken: [String]) -> Bool {
        taken.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
    }
}
