import ChirpCore
import ChirpFeatures
import Foundation
import XCTest

@testable import iChirp

/// Plan 023 lane 2 (UX audit F14): the app side of Capture's recipes. The recipe model, store, check and tap plan are
/// tested in ChirpKit (`CreateRecipeTests`); nothing here records (a Speak recipe's hand-off is not driven: it would
/// start the microphone).
@MainActor
final class CaptureRecipesAppTests: XCTestCase {
    func testTilesGoToOneColumnAtLargeText() {
        XCTAssertEqual(RecipeTile.columns(for: .large), 2)
        XCTAssertEqual(RecipeTile.columns(for: .xLarge), 2)
        XCTAssertEqual(RecipeTile.columns(for: .xxLarge), 1)
        XCTAssertEqual(RecipeTile.columns(for: .accessibility2), 1)
    }

    func testStartersKeepTheOldShortcutsWords() {
        XCTAssertEqual(RecipeWords.subtitle(.starter(.dictate), polishAfter: false), "Action Button or tap")
        XCTAssertEqual(RecipeWords.subtitle(.starter(.dictate), polishAfter: true), "Clean text on copy")
        XCTAssertEqual(RecipeWords.subtitle(.starter(.typeOrPaste), polishAfter: false), "Notes, any text")
        XCTAssertEqual(RecipeWords.subtitle(.starter(.pasteLink), polishAfter: false), "Podcast, YouTube, web link")
        XCTAssertEqual(RecipeWords.subtitle(.starter(.importFile), polishAfter: false), "Voice Memos, audio, PDF, Word")
        XCTAssertEqual(RecipeWords.systemImage(.starter(.importFile)), "square.and.arrow.down")
        XCTAssertTrue(RecipeWords.hint(.starter(.dictate)).hasPrefix("Starts dictating."))
    }

    func testASavedRecipeSaysWhatItAsksForAndItsModelInTheList() {
        let recipe = CreateRecipe(
            name: "Link → Summary", choices: CreateChoices(input: .link, output: .summary),
            modelID: "on-device", modelName: "Apple on-device model")
        XCTAssertEqual(RecipeWords.subtitle(recipe, polishAfter: false), "Paste a link", "Capture's tile stays short")
        XCTAssertEqual(
            RecipeWords.subtitle(recipe, polishAfter: false, withModel: true), "Paste a link · Apple on-device model")
        XCTAssertEqual(RecipeWords.hint(recipe), "Opens Create with this recipe's choices.")
        let transcript = CreateRecipe(name: "File → Transcript", choices: CreateChoices(input: .file))
        XCTAssertEqual(
            RecipeWords.subtitle(transcript, polishAfter: false, withModel: true), "Pick a file",
            "no model named when the output needs none")
    }

    func testCreateAndRecipesNameOutputsTheSameWay() {
        let soap = PromptTemplate(
            id: BuiltInTemplates.soapNote.id, name: "SOAP note", category: .deliverable, activeVersionID: UUID())
        XCTAssertEqual(
            CreateReadiness.outputTitle(for: .document(templateID: soap.id), templates: [soap]), "SOAP note")
        XCTAssertEqual(CreateReadiness.outputTitle(for: .document(templateID: UUID()), templates: [soap]), "Document")
        XCTAssertEqual(CreateReadiness.outputTitle(for: .summary, templates: []), "Summary")
        XCTAssertEqual(
            CreateReadiness.outputTitle(for: .voiceMessage(summarizeFirst: true), templates: []),
            "Voice message of a summary")
    }

    /// A Type or Link recipe opens Create with its own choices; a finished chain is dropped first. Nothing records.
    func testATypeOrLinkRecipeOpensCreateWithItsChoices() {
        let host = CreateHost(recipeStore: MemoryRecipes())
        XCTAssertEqual(host.recipes.recipes, CreateRecipe.starters, "a new host shows the starters")
        let recipe = CreateRecipe(
            name: "Link → Summary", choices: CreateChoices(input: .link, output: .summary, isClinical: true))
        host.open(recipe: recipe)
        XCTAssertTrue(host.isSheetPresented)
        XCTAssertEqual(host.pendingRecipe, recipe)
        XCTAssertNil(host.flow)
    }
}

/// Recipes in memory for app tests.
private final class MemoryRecipes: CreateRecipeStoring, @unchecked Sendable {
    private var saved: [CreateRecipe]?

    func load() -> [CreateRecipe]? { saved }

    func save(_ recipes: [CreateRecipe]) { saved = recipes }
}
