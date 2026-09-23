import ChirpCore
import Foundation

/// The Create sheet's last answers (plan 022 Step 3), remembered for the next time. Holds choices only: never text,
/// links or file names.
public struct CreateChoices: Codable, Sendable, Equatable {
    /// "What do you want?" without the template it may carry.
    public enum OutputKind: String, Codable, Sendable, CaseIterable {
        case transcript, summary, document, voiceMessage
    }

    public var input: CreateInputKind
    public var output: OutputKind
    /// The template of a Document output.
    public var templateID: UUID?
    /// Voice message of a summary instead of the whole text.
    public var voiceSummarizeFirst: Bool
    /// "Clinical (patient information)".
    public var isClinical: Bool

    public init(
        input: CreateInputKind = .speak,
        output: OutputKind = .transcript,
        templateID: UUID? = nil,
        voiceSummarizeFirst: Bool = false,
        isClinical: Bool = false
    ) {
        self.input = input
        self.output = output
        self.templateID = templateID
        self.voiceSummarizeFirst = voiceSummarizeFirst
        self.isClinical = isClinical
    }

    /// The chain's output, or nil for a Document without a template (the sheet asks for one).
    public var createOutput: CreateOutput? {
        switch output {
        case .transcript: .transcript
        case .summary: .summary
        case .document: templateID.map { .document(templateID: $0) }
        case .voiceMessage: .voiceMessage(summarizeFirst: voiceSummarizeFirst)
        }
    }

    /// The new item's class.
    public var privacyClass: PrivacyClass { isClinical ? .clinical : .personal }

    /// Keeps the template only while it still exists; a removed template falls back to no choice.
    public func validated(templateIDs: Set<UUID>) -> CreateChoices {
        var copy = self
        if let id = templateID, !templateIDs.contains(id) { copy.templateID = nil }
        return copy
    }
}

public protocol CreateChoicesStoring: Sendable {
    func load() -> CreateChoices
    func save(_ choices: CreateChoices)
}

/// `CreateChoices` as a JSON blob under `ichirp.create.choices`; missing or unreadable falls back to the defaults.
public final class UserDefaultsCreateChoicesStore: CreateChoicesStoring, @unchecked Sendable {
    public static let key = "ichirp.create.choices"

    private let defaults: UserDefaults
    private let logger = Log.logger("create")

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> CreateChoices {
        guard let data = defaults.data(forKey: Self.key) else { return CreateChoices() }
        do {
            return try JSONDecoder().decode(CreateChoices.self, from: data)
        } catch {
            logger.error("create_choices_decode_failed; using defaults")
            return CreateChoices()
        }
    }

    public func save(_ choices: CreateChoices) {
        do {
            defaults.set(try JSONEncoder().encode(choices), forKey: Self.key)
        } catch {
            logger.error("create_choices_encode_failed error_type=\(error.logTypeName, privacy: .public)")
        }
    }
}
