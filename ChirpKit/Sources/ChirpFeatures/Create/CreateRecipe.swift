import ChirpCore
import Foundation

// Plan 023 lane 2 (UX audit F14, the owner's "Create + recipes"): Create is Capture's one front door, and the four
// shortcuts that duplicated its inputs become remembered recipes, one tap each. Fresh implementation for iChirp.

/// A remembered Create run: Create's choices (what you have, what you want, the template, the voice-message variant
/// and the Clinical switch), the model chosen when it was saved, and a name ("Dictate → SOAP note").
///
/// - Recipes are settings, not Library data: JSON in UserDefaults (`UserDefaultsCreateRecipeStore`), never text, links,
///   file names or anything a recipe made. No database row, no migration.
/// - Running one starts the same `CreateFlow` with exactly these choices (`request(input:)`). A clinical recipe makes
///   its item clinical from the first write, like Create's switch; it never answers a clinical question, so a cloud
///   model or voice still asks every run.
/// - The four starters (`Starter`) keep Capture's former shortcuts exactly, so nothing is lost for a new user.
public struct CreateRecipe: Codable, Sendable, Equatable, Identifiable {
    /// Capture's former shortcuts, kept as they were: the ordinary dictation (copied when you stop), the Type or paste
    /// editor, the Paste a link sheet (Mac companion and documents included) and the multi-file import.
    public enum Starter: String, Codable, Sendable, CaseIterable {
        case dictate, typeOrPaste, pasteLink, importFile
    }

    /// Longest name kept; longer names are cut.
    public static let maxNameLength = 40

    public var id: UUID
    public var name: String
    /// Exactly what Create's questions held when the recipe was saved.
    public var choices: CreateChoices
    /// The model the recipe runs on (`LanguageModelChoice.id`) when its output needs one; nil means the default model
    /// at run time.
    public var modelID: String?
    /// That model's name when the recipe was saved, to say which one is missing.
    public var modelName: String?
    /// The template's name when the recipe was saved, to say which one is missing.
    public var templateName: String?
    /// Set on the four starters: they open today's shortcut instead of a chain.
    public var starter: Starter?

    public init(
        id: UUID = UUID(),
        name: String,
        choices: CreateChoices,
        modelID: String? = nil,
        modelName: String? = nil,
        templateName: String? = nil,
        starter: Starter? = nil
    ) {
        self.id = id
        self.name = name
        self.choices = choices
        self.modelID = modelID
        self.modelName = modelName
        self.templateName = templateName
        self.starter = starter
    }

    // MARK: - Starters

    /// The recipes Capture shows when none were ever saved, in the former shortcuts' order.
    public static var starters: [CreateRecipe] { Starter.allCases.map(starter) }

    public static func starter(_ starter: Starter) -> CreateRecipe {
        CreateRecipe(id: starter.id, name: starter.name, choices: starter.choices, starter: starter)
    }

    // MARK: - The chain

    /// The request for `input`, exactly as Create would make it from these choices; nil when `input` is not the
    /// recipe's kind or a Document has no template.
    public func request(input: CreateInput) -> CreateRequest? {
        guard input.kind == choices.input, let output = choices.createOutput else { return nil }
        return CreateRequest(input: input, output: output, privacyClass: choices.privacyClass)
    }

    /// The output needs a language model (Summary, a template, or a voice message of a summary).
    public var needsLanguageModel: Bool {
        choices.createOutput?.needsLanguageModel ?? (choices.output == .document)
    }

    /// The output needs a voice.
    public var needsVoice: Bool { choices.output == .voiceMessage }

    /// The model a run uses: the one saved with the recipe, or `defaultID`.
    public func runModelID(default defaultID: String) -> String { modelID ?? defaultID }

    /// Two recipes that would run the same way (the name aside).
    public func runsLike(_ other: CreateRecipe) -> Bool {
        starter == other.starter && choices.input == other.choices.input
            && choices.createOutput == other.choices.createOutput && choices.isClinical == other.choices.isClinical
            && modelID == other.modelID
    }

    // MARK: - Words

    /// "Dictate → SOAP note", "Link → Summary", "Type → Voice message".
    public static func suggestedName(for choices: CreateChoices, templateName: String?) -> String {
        "\(inputWord(choices.input)) → \(outputWord(choices, templateName: templateName))"
    }

    /// A typed name trimmed to one line and `maxNameLength`; nil when nothing is left.
    public static func cleanName(_ raw: String) -> String? {
        let oneLine = raw.components(separatedBy: .newlines).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        guard !oneLine.isEmpty else { return nil }
        return String(oneLine.prefix(maxNameLength)).trimmingCharacters(in: .whitespaces)
    }

    /// The name as VoiceOver should say it: "Dictate, then SOAP note".
    public var spokenName: String {
        name.replacingOccurrences(of: " → ", with: ", then ").replacingOccurrences(of: "→", with: ", then ")
    }

    /// The whole recipe in words, for VoiceOver after the name: what it asks for, what it makes, the model, Clinical.
    public var spokenDescription: String {
        if let starter { return starter.spokenDescription }
        var sentences = ["\(Self.inputPhrase(choices.input)), then \(outputPhrase)."]
        if needsLanguageModel { sentences.append("Runs on \(modelName ?? "your default model").") }
        if choices.isClinical {
            sentences.append(
                "Clinical: marked clinical from the start; cloud models and voices ask before anything is sent.")
        }
        return sentences.joined(separator: " ")
    }

    /// The full VoiceOver label: the name, then the whole recipe.
    public var accessibilityLabel: String { "\(spokenName). \(spokenDescription)" }

    static func inputWord(_ kind: CreateInputKind) -> String {
        switch kind {
        case .speak: "Dictate"
        case .text: "Type"
        case .link: "Link"
        case .file: "File"
        }
    }

    static func outputWord(_ choices: CreateChoices, templateName: String?) -> String {
        switch choices.output {
        case .transcript: "Transcript"
        case .summary: "Summary"
        case .document: templateName ?? "Document"
        case .voiceMessage: choices.voiceSummarizeFirst ? "Voice summary" : "Voice message"
        }
    }

    static func inputPhrase(_ kind: CreateInputKind) -> String {
        switch kind {
        case .speak: "Speak"
        case .text: "Type or paste text"
        case .link: "Paste a link"
        case .file: "Pick a file"
        }
    }

    private var outputPhrase: String {
        switch choices.output {
        case .transcript: choices.input == .text ? "save it in your Library" : "get the transcript"
        case .summary: "get a summary"
        case .document: "make a \(templateName ?? "document")"
        case .voiceMessage: choices.voiceSummarizeFirst ? "get a voice message of a summary" : "get a voice message"
        }
    }
}

extension CreateRecipe.Starter {
    /// Fixed, so a starter keeps its identity whether or not the list was ever saved.
    public var id: UUID {
        switch self {
        case .dictate: UUID(uuidString: "F14C0DE0-0000-4000-8000-000000000001")!
        case .typeOrPaste: UUID(uuidString: "F14C0DE0-0000-4000-8000-000000000002")!
        case .pasteLink: UUID(uuidString: "F14C0DE0-0000-4000-8000-000000000003")!
        case .importFile: UUID(uuidString: "F14C0DE0-0000-4000-8000-000000000004")!
        }
    }

    public var name: String {
        switch self {
        case .dictate: "Dictate"
        case .typeOrPaste: "Type or paste"
        case .pasteLink: "Paste a link"
        case .importFile: "Import a file"
        }
    }

    /// What Create would call it: the input, and the item itself as the output.
    public var choices: CreateChoices {
        switch self {
        case .dictate: CreateChoices(input: .speak, output: .transcript)
        case .typeOrPaste: CreateChoices(input: .text, output: .transcript)
        case .pasteLink: CreateChoices(input: .link, output: .transcript)
        case .importFile: CreateChoices(input: .file, output: .transcript)
        }
    }

    public var spokenDescription: String {
        switch self {
        case .dictate: "Starts dictating. The text is copied when you stop."
        case .typeOrPaste: "Opens an editor. The text is saved in your Library."
        case .pasteLink: "Opens Paste a link: a podcast, YouTube or web link, or a document."
        case .importFile: "Opens Files. Audio and video are transcribed; PDF, Word and text are read."
        }
    }
}

// MARK: - Before a recipe runs

/// Whether a recipe can run now. When something it needs is gone or not set up, one sentence says what, and nothing
/// starts: no item, no recording, no model call. Starters are never checked here (their own screens say what is
/// missing, as before).
public enum CreateRecipeCheck {
    /// - Parameters:
    ///   - templateIDs: the templates that exist now.
    ///   - modelIDs: the models a run could use now (`LanguageModelsViewModel.choices`' ids).
    ///   - modelProblem: why the model the recipe resolves to cannot run now, or nil.
    ///   - voiceProblem: why no voice can speak now (Settings → Voices), or nil.
    ///   - speechModelReady: the speech model for Speak is downloaded.
    public static func problem(
        _ recipe: CreateRecipe,
        templateIDs: Set<UUID>,
        modelIDs: Set<String>,
        modelProblem: String?,
        voiceProblem: String?,
        speechModelReady: Bool
    ) -> String? {
        guard recipe.starter == nil else { return nil }
        let choices = recipe.choices
        if choices.output == .document {
            guard let id = choices.templateID, templateIDs.contains(id) else {
                let what =
                    recipe.templateName.map { "“\($0)”, the template this recipe makes," }
                    ?? "The template this recipe makes"
                return "\(what) no longer exists. Make the recipe again in Create, or delete it."
            }
        }
        if recipe.needsLanguageModel {
            if let id = recipe.modelID, !modelIDs.contains(id) {
                let what =
                    recipe.modelName.map { "“\($0)”, the model this recipe runs on," }
                    ?? "The model this recipe runs on"
                return "\(what) is not set up any more. Set it up again in Settings → Models, or make the recipe again "
                    + "in Create."
            }
            if let modelProblem { return modelProblem }
        }
        if recipe.needsVoice, let voiceProblem {
            return "This recipe makes a voice message, and no voice can speak it now. \(voiceProblem)"
        }
        if choices.input == .speak, !speechModelReady {
            return "Download the speech model in Settings → Speech to speak."
        }
        return nil
    }
}

/// What one tap on a recipe does.
public enum CreateRecipeLaunch: Sendable, Equatable {
    /// A starter: the shortcut it keeps.
    case starter(CreateRecipe.Starter)
    /// Speak: straight to the Dictating screen (its chip says "Then: <output>"); the chain continues in Create.
    case speak(CreateRequest)
    /// Type or Link: Create opens with the recipe's choices, for the text or the link.
    case openCreate(CreateChoices)
    /// File: the file picker, then the chain.
    case pickFile(CreateChoices)
    /// A Create chain is still running or waiting for an answer: return to it; nothing new starts.
    case busy
    /// Something the recipe needs is missing (the sentence says what); nothing starts.
    case blocked(String)

    /// - Parameters:
    ///   - problem: `CreateRecipeCheck.problem` for this recipe now.
    ///   - chainIsActive: a Create chain is running or waiting for an answer.
    public static func plan(_ recipe: CreateRecipe, problem: String?, chainIsActive: Bool) -> CreateRecipeLaunch {
        if let starter = recipe.starter { return .starter(starter) }
        if let problem { return .blocked(problem) }
        guard recipe.choices.createOutput != nil else {
            return .blocked("This recipe has no template. Make it again in Create, or delete it.")
        }
        if chainIsActive { return .busy }
        switch recipe.choices.input {
        case .speak:
            guard let request = recipe.request(input: .speak) else {
                return .blocked("This recipe cannot start. Make it again in Create.")
            }
            return .speak(request)
        case .text, .link: return .openCreate(recipe.choices)
        case .file: return .pickFile(recipe.choices)
        }
    }
}

// MARK: - Storage

public protocol CreateRecipeStoring: Sendable {
    /// The saved recipes in order, or nil when none were ever saved (Capture shows the starters then).
    func load() -> [CreateRecipe]?
    func save(_ recipes: [CreateRecipe])
}

/// The recipes as JSON under `ichirp.create.recipes` (`{"version":1,"recipes":[…]}`). An empty saved list stays empty
/// (the owner deleted them all). One recipe that cannot be read is skipped; a list that cannot be read at all shows the
/// starters and is copied once to `ichirp.create.recipes.unreadable` instead of being overwritten unseen.
public final class UserDefaultsCreateRecipeStore: CreateRecipeStoring, @unchecked Sendable {
    public static let key = "ichirp.create.recipes"
    public static let unreadableKey = "ichirp.create.recipes.unreadable"
    static let version = 1

    private let defaults: UserDefaults
    private let logger = Log.logger("create")

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> [CreateRecipe]? {
        guard let data = defaults.data(forKey: Self.key) else { return nil }
        do {
            let stored = try JSONDecoder().decode(StoredList.self, from: data)
            let recipes = stored.recipes.compactMap(\.recipe)
            if recipes.count < stored.recipes.count {
                logger.error(
                    "create_recipes_skipped count=\(stored.recipes.count - recipes.count, privacy: .public)")
            }
            return recipes
        } catch {
            logger.error("create_recipes_decode_failed; showing the starters")
            if defaults.data(forKey: Self.unreadableKey) == nil { defaults.set(data, forKey: Self.unreadableKey) }
            return nil
        }
    }

    public func save(_ recipes: [CreateRecipe]) {
        do {
            let data = try JSONEncoder().encode(SavedList(version: Self.version, recipes: recipes))
            defaults.set(data, forKey: Self.key)
        } catch {
            logger.error("create_recipes_encode_failed error_type=\(error.logTypeName, privacy: .public)")
        }
    }

    private struct SavedList: Encodable {
        var version: Int
        var recipes: [CreateRecipe]
    }

    private struct StoredList: Decodable {
        var version: Int
        var recipes: [LenientRecipe]
    }

    /// One recipe, or nil when it cannot be read (a newer build's input or output kind).
    private struct LenientRecipe: Decodable {
        let recipe: CreateRecipe?

        init(from decoder: any Decoder) throws {
            recipe = try? CreateRecipe(from: decoder)
        }
    }
}
