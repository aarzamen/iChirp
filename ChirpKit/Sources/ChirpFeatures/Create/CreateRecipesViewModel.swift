import ChirpCore
import Foundation
import Observation

/// The owner's recipes (plan 023 lane 2): Capture shows the first `captureCount` as one-tap tiles; Create saves new ones
/// ("Save as recipe"); the Recipes sheet renames, reorders and deletes them. Every change is saved at once through
/// `CreateRecipeStoring`. When none were ever saved, the four starters show.
@MainActor @Observable public final class CreateRecipesViewModel {
    /// Tiles on Capture.
    public static let captureCount = 4
    /// The most recipes kept.
    public static let maxCount = 12

    public enum SaveResult: Sendable, Equatable {
        /// Saved, first in the list (so it shows on Capture at once).
        case saved(CreateRecipe)
        /// A recipe that runs the same way already exists; nothing was saved.
        case duplicate(CreateRecipe)
        /// `maxCount` recipes already; nothing was saved.
        case full
        /// A Document without a template cannot be a recipe; nothing was saved.
        case incomplete
    }

    public private(set) var recipes: [CreateRecipe]

    @ObservationIgnored private let store: any CreateRecipeStoring
    @ObservationIgnored private let logger = Log.logger("create")

    public init(store: any CreateRecipeStoring) {
        self.store = store
        recipes = store.load() ?? CreateRecipe.starters
    }

    /// The tiles on Capture, in order.
    public var onCapture: [CreateRecipe] { Array(recipes.prefix(Self.captureCount)) }

    public var isFull: Bool { recipes.count >= Self.maxCount }

    /// Starters the owner deleted, in their order (the Recipes sheet offers them back).
    public var missingStarters: [CreateRecipe.Starter] {
        CreateRecipe.Starter.allCases.filter { starter in !recipes.contains { $0.starter == starter } }
    }

    /// Re-reads the store (another screen may have saved).
    public func reload() {
        recipes = store.load() ?? CreateRecipe.starters
    }

    /// A saved recipe that would run like these choices and model, if any.
    public func existing(choices: CreateChoices, modelID: String?) -> CreateRecipe? {
        let candidate = Self.recipe(name: "", choices: choices, modelID: modelID, modelName: nil, templateName: nil)
        return recipes.first { $0.runsLike(candidate) }
    }

    /// Saves Create's choices as a recipe named `name` (the suggested name when blank). The model is kept only when
    /// the output needs one, the template name only for a Document.
    @discardableResult
    public func save(
        name: String, choices: CreateChoices, modelID: String?, modelName: String?, templateName: String?
    ) -> SaveResult {
        guard choices.createOutput != nil else { return .incomplete }
        let recipe = Self.recipe(
            name: name, choices: choices, modelID: modelID, modelName: modelName, templateName: templateName)
        if let same = recipes.first(where: { $0.runsLike(recipe) }) { return .duplicate(same) }
        guard !isFull else { return .full }
        recipes.insert(recipe, at: 0)
        persist()
        logger.notice(
            "create_recipe_saved input=\(choices.input.rawValue, privacy: .public) output=\(choices.output.rawValue, privacy: .public) clinical=\(choices.isClinical, privacy: .public)"
        )
        return .saved(recipe)
    }

    /// Renames a recipe; a blank name is refused (the old name stays).
    @discardableResult
    public func rename(_ id: UUID, to name: String) -> Bool {
        guard let clean = CreateRecipe.cleanName(name), let index = recipes.firstIndex(where: { $0.id == id }) else {
            return false
        }
        recipes[index].name = clean
        persist()
        return true
    }

    /// Deletes a recipe. Only the recipe goes; nothing in the Library changes.
    public func delete(_ id: UUID) {
        guard let index = recipes.firstIndex(where: { $0.id == id }) else { return }
        recipes.remove(at: index)
        persist()
    }

    /// Puts the recipes in `ids`' order. Ignored unless `ids` names every recipe exactly once.
    public func reorder(_ ids: [UUID]) {
        guard ids.count == recipes.count, Set(ids) == Set(recipes.map(\.id)) else { return }
        let byID = Dictionary(uniqueKeysWithValues: recipes.map { ($0.id, $0) })
        recipes = ids.compactMap { byID[$0] }
        persist()
    }

    public func canMoveUp(_ id: UUID) -> Bool { (recipes.firstIndex { $0.id == id } ?? 0) > 0 }

    public func canMoveDown(_ id: UUID) -> Bool {
        guard let index = recipes.firstIndex(where: { $0.id == id }) else { return false }
        return index < recipes.count - 1
    }

    public func moveUp(_ id: UUID) {
        guard let index = recipes.firstIndex(where: { $0.id == id }), index > 0 else { return }
        recipes.swapAt(index, index - 1)
        persist()
    }

    public func moveDown(_ id: UUID) {
        guard let index = recipes.firstIndex(where: { $0.id == id }), index < recipes.count - 1 else { return }
        recipes.swapAt(index, index + 1)
        persist()
    }

    /// Adds the deleted starters back at the end, in their order (never more than `maxCount` in all).
    public func restoreStarters() {
        let room = max(0, Self.maxCount - recipes.count)
        let missing = missingStarters.prefix(room).map(CreateRecipe.starter)
        guard !missing.isEmpty else { return }
        recipes.append(contentsOf: missing)
        persist()
    }

    private func persist() {
        store.save(recipes)
    }

    private static func recipe(
        name: String, choices: CreateChoices, modelID: String?, modelName: String?, templateName: String?
    ) -> CreateRecipe {
        let usesModel = choices.createOutput?.needsLanguageModel ?? false
        let isDocument = choices.output == .document
        let keptTemplateName = isDocument ? templateName : nil
        return CreateRecipe(
            name: CreateRecipe.cleanName(name)
                ?? CreateRecipe.suggestedName(for: choices, templateName: keptTemplateName),
            choices: choices,
            modelID: usesModel ? modelID : nil,
            modelName: usesModel ? modelName : nil,
            templateName: keptTemplateName)
    }
}
