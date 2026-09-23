import ChirpCore
import Foundation
import XCTest

@testable import ChirpFeatures

/// Plan 023 lane 2 (UX audit F14): recipes are Create's remembered choices, one tap on Capture. The store keeps them in
/// order as settings; the starters show when none were saved; a recipe runs exactly its choices; Clinical makes the item
/// clinical first and never skips a question; a recipe that needs something now missing says what and does not start.
/// Everything is synthetic; Speak runs only through the fake dictation.
@MainActor
final class CreateRecipeTests: XCTestCase {
    private func makeDefaults() throws -> UserDefaults {
        try XCTUnwrap(UserDefaults(suiteName: "CreateRecipeTests-\(UUID().uuidString)"))
    }

    private static let soap = BuiltInTemplates.soapNote.id

    // MARK: - Store: round trip and order

    func testStoreRoundTripKeepsEveryFieldAndTheOrder() throws {
        let defaults = try makeDefaults()
        let store = UserDefaultsCreateRecipeStore(defaults: defaults)
        XCTAssertNil(store.load(), "nothing saved yet")

        let recipes = [
            CreateRecipe(
                name: "Dictate → SOAP note",
                choices: CreateChoices(input: .speak, output: .document, templateID: Self.soap, isClinical: true),
                modelID: "on-device", modelName: "Apple on-device model", templateName: "SOAP note"),
            CreateRecipe.starter(.pasteLink),
            CreateRecipe(
                name: "Type → Voice message",
                choices: CreateChoices(input: .text, output: .voiceMessage, voiceSummarizeFirst: true)),
        ]
        store.save(recipes)
        XCTAssertEqual(store.load(), recipes)
        XCTAssertEqual(store.load()?.map(\.name), ["Dictate → SOAP note", "Paste a link", "Type → Voice message"])

        // A second store over the same defaults (the next launch) reads the same list.
        XCTAssertEqual(UserDefaultsCreateRecipeStore(defaults: defaults).load(), recipes)
    }

    func testReorderMoveRenameAndDeleteAreSavedAtOnce() throws {
        let defaults = try makeDefaults()
        let model = CreateRecipesViewModel(store: UserDefaultsCreateRecipeStore(defaults: defaults))
        let ids = model.recipes.map(\.id)
        XCTAssertEqual(ids.count, 4)

        model.reorder(ids.reversed())
        XCTAssertEqual(model.recipes.map(\.name), ["Import a file", "Paste a link", "Type or paste", "Dictate"])
        model.moveUp(CreateRecipe.Starter.dictate.id)
        XCTAssertEqual(model.recipes.map(\.name), ["Import a file", "Paste a link", "Dictate", "Type or paste"])
        model.moveDown(CreateRecipe.Starter.importFile.id)
        XCTAssertEqual(model.recipes.map(\.name), ["Paste a link", "Import a file", "Dictate", "Type or paste"])
        XCTAssertFalse(model.canMoveUp(CreateRecipe.Starter.pasteLink.id))
        XCTAssertFalse(model.canMoveDown(CreateRecipe.Starter.typeOrPaste.id))

        model.reorder([ids[0], ids[1]])
        XCTAssertEqual(model.recipes.count, 4, "a partial order is ignored, nothing is dropped")

        XCTAssertTrue(model.rename(CreateRecipe.Starter.dictate.id, to: "  Quick note\n "))
        XCTAssertFalse(model.rename(CreateRecipe.Starter.dictate.id, to: "   "), "a blank name is refused")
        model.delete(CreateRecipe.Starter.typeOrPaste.id)

        let reread = CreateRecipesViewModel(store: UserDefaultsCreateRecipeStore(defaults: defaults))
        XCTAssertEqual(reread.recipes.map(\.name), ["Paste a link", "Import a file", "Quick note"])
        XCTAssertEqual(reread.recipes.map(\.starter), [.pasteLink, .importFile, .dictate], "a renamed starter keeps its shortcut")
    }

    func testANewRecipeGoesFirstSoItShowsOnCapture() throws {
        let model = CreateRecipesViewModel(store: UserDefaultsCreateRecipeStore(defaults: try makeDefaults()))
        let choices = CreateChoices(input: .link, output: .summary)
        let result = model.save(
            name: "", choices: choices, modelID: "on-device", modelName: "Apple on-device model", templateName: nil)
        guard case .saved(let recipe) = result else { return XCTFail("expected a saved recipe, got \(result)") }
        XCTAssertEqual(recipe.name, "Link → Summary", "a blank name takes the suggestion")
        XCTAssertEqual(model.onCapture.map(\.name), ["Link → Summary", "Dictate", "Type or paste", "Paste a link"])
        XCTAssertEqual(model.recipes.count, 5, "Import a file is still a recipe, past the four on Capture")

        XCTAssertEqual(
            model.save(
                name: "Other name", choices: choices, modelID: "on-device", modelName: nil, templateName: nil),
            .duplicate(recipe), "the same choices and model are not saved twice")
        XCTAssertEqual(
            model.save(
                name: "", choices: CreateChoices(input: .speak, output: .document), modelID: nil, modelName: nil,
                templateName: nil),
            .incomplete, "a Document needs its template")

        for index in 0..<(CreateRecipesViewModel.maxCount - model.recipes.count) {
            _ = model.save(
                name: "Synthetic \(index)",
                choices: CreateChoices(input: .text, output: .document, templateID: UUID()), modelID: nil,
                modelName: nil, templateName: "Synthetic")
        }
        XCTAssertTrue(model.isFull)
        XCTAssertEqual(
            model.save(
                name: "", choices: CreateChoices(input: .file, output: .summary), modelID: nil, modelName: nil,
                templateName: nil),
            .full)
    }

    // MARK: - Defaults

    func testTheStartersShowWhenNoneWereSaved() throws {
        let defaults = try makeDefaults()
        let model = CreateRecipesViewModel(store: UserDefaultsCreateRecipeStore(defaults: defaults))
        XCTAssertEqual(model.recipes, CreateRecipe.starters)
        XCTAssertEqual(model.onCapture.map(\.name), ["Dictate", "Type or paste", "Paste a link", "Import a file"])
        XCTAssertEqual(model.onCapture.map(\.starter), [.dictate, .typeOrPaste, .pasteLink, .importFile])
        XCTAssertEqual(
            model.onCapture.map(\.choices.input), [.speak, .text, .link, .file], "the starters are Create's four inputs")
        XCTAssertTrue(model.onCapture.allSatisfy { $0.choices.output == .transcript && !$0.choices.isClinical })
        XCTAssertNil(defaults.data(forKey: UserDefaultsCreateRecipeStore.key), "showing the starters saves nothing")
        for starter in CreateRecipe.starters {
            XCTAssertEqual(
                CreateRecipeLaunch.plan(starter, problem: "ignored", chainIsActive: true),
                .starter(try XCTUnwrap(starter.starter)), "a starter keeps today's shortcut")
        }
    }

    func testDeletingEveryRecipeStaysDeletedAndTheStartersCanComeBack() throws {
        let defaults = try makeDefaults()
        let model = CreateRecipesViewModel(store: UserDefaultsCreateRecipeStore(defaults: defaults))
        for recipe in model.recipes { model.delete(recipe.id) }
        XCTAssertTrue(model.recipes.isEmpty)
        let reread = CreateRecipesViewModel(store: UserDefaultsCreateRecipeStore(defaults: defaults))
        XCTAssertTrue(reread.recipes.isEmpty, "the owner deleted them all; they do not come back by themselves")
        XCTAssertEqual(reread.missingStarters, CreateRecipe.Starter.allCases)
        reread.restoreStarters()
        XCTAssertEqual(reread.recipes, CreateRecipe.starters)
        XCTAssertTrue(reread.missingStarters.isEmpty)
    }

    func testAnUnreadableListShowsTheStartersAndIsKept() throws {
        let defaults = try makeDefaults()
        let store = UserDefaultsCreateRecipeStore(defaults: defaults)
        defaults.set(Data("not json".utf8), forKey: UserDefaultsCreateRecipeStore.key)
        XCTAssertNil(store.load())
        XCTAssertEqual(CreateRecipesViewModel(store: store).recipes, CreateRecipe.starters)
        XCTAssertEqual(
            defaults.data(forKey: UserDefaultsCreateRecipeStore.unreadableKey), Data("not json".utf8),
            "kept once instead of being overwritten unseen")

        // One recipe from a newer build (an input this build does not know) is skipped; the rest stay.
        let known = CreateRecipe(name: "Link → Summary", choices: CreateChoices(input: .link, output: .summary))
        let knownJSON = String(decoding: try JSONEncoder().encode(known), as: UTF8.self)
        let unknownJSON = knownJSON.replacingOccurrences(of: "\"link\"", with: "\"hologram\"")
        let list = "{\"version\":1,\"recipes\":[\(unknownJSON),\(knownJSON)]}"
        defaults.set(Data(list.utf8), forKey: UserDefaultsCreateRecipeStore.key)
        XCTAssertEqual(store.load(), [known])
    }

    // MARK: - A recipe is exactly Create's choices

    func testARecipeMapsExactlyToCreateChoices() throws {
        let samples: [CreateInputKind: CreateInput] = [
            .speak: .speak,
            .text: .text("Synthetic note"),
            .link: .link("https://example.com/synthetic-episode.mp3"),
            .file: .file(URL(fileURLWithPath: "/tmp/synthetic-memo.m4a")),
        ]
        for input in CreateInputKind.allCases {
            for output in CreateChoices.OutputKind.allCases {
                for isClinical in [false, true] {
                    for summarizeFirst in [false, true] {
                        let choices = CreateChoices(
                            input: input, output: output, templateID: Self.soap, voiceSummarizeFirst: summarizeFirst,
                            isClinical: isClinical)
                        let label = "\(input) → \(output) clinical=\(isClinical) summary=\(summarizeFirst)"
                        let model = CreateRecipesViewModel(store: MemoryRecipeStore())
                        let result = model.save(
                            name: "", choices: choices, modelID: "on-device", modelName: "Apple on-device model",
                            templateName: "SOAP note")
                        guard case .saved(let recipe) = result else { return XCTFail("\(label): \(result)") }
                        XCTAssertEqual(model.recipes.first, recipe, label)
                        let sample = try XCTUnwrap(samples[input])
                        XCTAssertEqual(recipe.choices, choices, label)
                        XCTAssertEqual(
                            recipe.request(input: sample),
                            CreateRequest(
                                input: sample, output: try XCTUnwrap(choices.createOutput),
                                privacyClass: isClinical ? .clinical : .personal),
                            label)
                        let other = try XCTUnwrap(samples[input == .speak ? .text : .speak])
                        XCTAssertNil(recipe.request(input: other), "another input kind is not this recipe: \(label)")
                        XCTAssertEqual(
                            recipe.modelID, choices.createOutput?.needsLanguageModel == true ? "on-device" : nil,
                            "the model is kept only when the output needs one: \(label)")

                        let launch = CreateRecipeLaunch.plan(recipe, problem: nil, chainIsActive: false)
                        switch input {
                        case .speak: XCTAssertEqual(launch, .speak(try XCTUnwrap(recipe.request(input: .speak))), label)
                        case .text, .link: XCTAssertEqual(launch, .openCreate(choices), label)
                        case .file: XCTAssertEqual(launch, .pickFile(choices), label)
                        }
                        XCTAssertEqual(
                            CreateRecipeLaunch.plan(recipe, problem: nil, chainIsActive: true), .busy,
                            "a running chain is never replaced: \(label)")
                    }
                }
            }
        }
    }

    func testNamesAndVoiceOverReadTheWholeRecipe() {
        let soap = CreateChoices(input: .speak, output: .document, templateID: Self.soap, isClinical: true)
        XCTAssertEqual(CreateRecipe.suggestedName(for: soap, templateName: "SOAP note"), "Dictate → SOAP note")
        XCTAssertEqual(
            CreateRecipe.suggestedName(for: CreateChoices(input: .link, output: .summary), templateName: nil),
            "Link → Summary")
        XCTAssertEqual(
            CreateRecipe.suggestedName(for: CreateChoices(input: .text, output: .voiceMessage), templateName: nil),
            "Type → Voice message")
        XCTAssertEqual(
            CreateRecipe.suggestedName(
                for: CreateChoices(input: .file, output: .voiceMessage, voiceSummarizeFirst: true), templateName: nil),
            "File → Voice summary")
        XCTAssertEqual(CreateRecipe.cleanName(String(repeating: "a", count: 60))?.count, CreateRecipe.maxNameLength)
        XCTAssertNil(CreateRecipe.cleanName(" \n "))

        let recipe = CreateRecipe(
            name: "Dictate → SOAP note", choices: soap, modelID: "on-device", modelName: "Apple on-device model",
            templateName: "SOAP note")
        XCTAssertEqual(
            recipe.accessibilityLabel,
            "Dictate, then SOAP note. Speak, then make a SOAP note. Runs on Apple on-device model. Clinical: marked "
                + "clinical from the start; cloud models and voices ask before anything is sent.")
        let starter = CreateRecipe.starter(.typeOrPaste)
        XCTAssertTrue(starter.accessibilityLabel.hasPrefix("Type or paste. "), "UI tests find the tile by its name")
    }

    // MARK: - Clinical: the item is clinical first; every question still appears

    func testAClinicalRecipeMakesItsItemClinicalBeforeAnyOtherStep() async throws {
        let samples: [CreateInput] = [
            .speak,
            .text("Synthetic note \(CreateFlowTests.marker)"),
            .link("https://example.com/synthetic-episode.mp3"),
            .file(URL(fileURLWithPath: "/tmp/synthetic-memo.m4a")),
        ]
        for input in samples {
            let label = "\(input.kind)"
            let recipe = CreateRecipe(
                name: "Synthetic", choices: CreateChoices(input: input.kind, output: .summary, isClinical: true),
                modelID: "cloud", modelName: "Synthetic cloud")
            let request = try XCTUnwrap(recipe.request(input: input), label)
            XCTAssertEqual(request.privacyClass, .clinical, label)

            let harness = try await CreateHarness()
            let flow = harness.makeFlow()
            let cloud = RecordingLanguageModel(locality: .cloud, host: "api.example.com")
            await flow.start(request, makeModel: { cloud })

            XCTAssertEqual(flow.phase, .waitingForAnswer(.operation), "the recipe never answers the question: \(label)")
            XCTAssertTrue(cloud.requests.isEmpty, "nothing is sent before the answer: \(label)")
            let id = try XCTUnwrap(flow.itemID, label)
            let row = try await harness.transcripts.fetch(id: id)
            XCTAssertEqual(row?.privacyClass, .clinical, label)
            let history = await harness.transcripts.classHistory(id)
            if input.kind == .speak {
                // The Dictating screen makes its row; the chain raises it the moment it learns the id, before any
                // other step (the fake dictation's row is Personal until then).
                XCTAssertEqual(history.last, .clinical, label)
            } else {
                XCTAssertEqual(Set(history), [.clinical], "clinical from the first write: \(label)")
            }
        }
    }

    // MARK: - Something missing: say what, start nothing

    func testARecipeWhoseTemplateModelOrVoiceIsGoneSaysWhatAndDoesNotStart() throws {
        let soap = CreateRecipe(
            name: "Dictate → SOAP note",
            choices: CreateChoices(input: .speak, output: .document, templateID: Self.soap, isClinical: true),
            modelID: "provider-1", modelName: "Synthetic cloud", templateName: "SOAP note")
        let everything = (
            templates: Set([Self.soap]), models: Set(["on-device", "provider-1"])
        )

        func check(
            _ recipe: CreateRecipe, templates: Set<UUID>? = nil, models: Set<String>? = nil,
            modelProblem: String? = nil, voiceProblem: String? = nil, speechReady: Bool = true
        ) -> String? {
            CreateRecipeCheck.problem(
                recipe, templateIDs: templates ?? everything.templates, modelIDs: models ?? everything.models,
                modelProblem: modelProblem, voiceProblem: voiceProblem, speechModelReady: speechReady)
        }

        XCTAssertNil(check(soap))
        XCTAssertEqual(
            CreateRecipeLaunch.plan(soap, problem: nil, chainIsActive: false),
            .speak(CreateRequest(input: .speak, output: .document(templateID: Self.soap), privacyClass: .clinical)))

        let noTemplate = check(soap, templates: [])
        XCTAssertEqual(
            noTemplate,
            "“SOAP note”, the template this recipe makes, no longer exists. Make the recipe again in Create, or delete it.")
        XCTAssertEqual(CreateRecipeLaunch.plan(soap, problem: noTemplate, chainIsActive: false), .blocked(try XCTUnwrap(noTemplate)))

        let noModel = check(soap, models: ["on-device"])
        XCTAssertEqual(
            noModel,
            "“Synthetic cloud”, the model this recipe runs on, is not set up any more. Set it up again in Settings → "
                + "Models, or make the recipe again in Create.")
        XCTAssertEqual(CreateRecipeLaunch.plan(soap, problem: noModel, chainIsActive: false), .blocked(try XCTUnwrap(noModel)))
        XCTAssertEqual(
            check(soap, modelProblem: "Apple Intelligence is turned off."), "Apple Intelligence is turned off.",
            "a model that exists but cannot run now says why")

        let voice = CreateRecipe(
            name: "Type → Voice message", choices: CreateChoices(input: .text, output: .voiceMessage))
        XCTAssertNil(check(voice, models: []), "a voice message of the whole text needs no model")
        let noVoice = check(voice, voiceProblem: "Choose Mac companion or Grok voices in Settings → Voices.")
        XCTAssertEqual(
            noVoice,
            "This recipe makes a voice message, and no voice can speak it now. Choose Mac companion or Grok voices in "
                + "Settings → Voices.")
        XCTAssertEqual(CreateRecipeLaunch.plan(voice, problem: noVoice, chainIsActive: false), .blocked(try XCTUnwrap(noVoice)))

        XCTAssertEqual(
            check(soap, speechReady: false), "Download the speech model in Settings → Speech to speak.",
            "Speak needs the speech model")
        XCTAssertNil(
            check(CreateRecipe.starter(.dictate), templates: [], models: [], voiceProblem: "x", speechReady: false),
            "starters are not checked here; their own screens say what is missing")

        // A recipe saved with the default model (no model id) is checked against the model that runs now.
        let summary = CreateRecipe(name: "Link → Summary", choices: CreateChoices(input: .link, output: .summary))
        XCTAssertNil(check(summary, models: []))
        XCTAssertEqual(summary.runModelID(default: "on-device"), "on-device")
    }
}

/// Recipes in memory (one list per test).
final class MemoryRecipeStore: CreateRecipeStoring, @unchecked Sendable {
    private(set) var saved: [CreateRecipe]?

    init(_ saved: [CreateRecipe]? = nil) {
        self.saved = saved
    }

    func load() -> [CreateRecipe]? { saved }

    func save(_ recipes: [CreateRecipe]) { saved = recipes }
}
