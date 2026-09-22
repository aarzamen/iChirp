import ChirpCore
import ChirpText
import Foundation
import XCTest

@testable import ChirpFeatures

/// M2 Step 5: the custom words and snippets editor, and Clean applying a stored custom word end to end — in the file
/// pipeline (Clean clean-up mode) and in dictation ("Polish after").
@MainActor
final class TextRulesViewModelTests: XCTestCase {
    func testAddEditToggleAndDeleteWordsAndSnippets() async throws {
        let store = FakeTextRulesStore()
        let model = TextRulesViewModel(store: store)
        await model.load()
        XCTAssertEqual(model.count, 0)

        let added = await model.addWord("  kubernetes ", replacement: " Kubernetes ")
        XCTAssertTrue(added)
        XCTAssertEqual(model.words.map(\.word), ["kubernetes"])
        XCTAssertEqual(model.words.first?.replacement, "Kubernetes")
        _ = await model.addWord("Aaron", replacement: "   ")
        XCTAssertNil(model.words.first { $0.word == "Aaron" }?.replacement, "a blank replacement is none")

        var word = try XCTUnwrap(model.words.first { $0.word == "kubernetes" })
        word.isEnabled = false
        let updated = await model.update(word)
        XCTAssertTrue(updated)
        XCTAssertEqual(model.words.first { $0.id == word.id }?.isEnabled, false)

        _ = await model.addSnippet(trigger: "my address", expansion: "1 Infinite Loop")
        XCTAssertEqual(model.count, 3)
        await model.deleteWords([word.id])
        await model.deleteSnippets(Set(model.snippets.map(\.id)))
        XCTAssertEqual(model.count, 1)
        let stored = try await store.customWords()
        XCTAssertEqual(stored.map(\.word), ["Aaron"])
    }

    func testEmptyFieldsAndDuplicatesAreRefusedWithAReadableError() async throws {
        let model = TextRulesViewModel(store: FakeTextRulesStore())
        let empty = await model.addWord("   ")
        XCTAssertFalse(empty)
        XCTAssertEqual(model.lastError, "Type the word Parakeet should write.")
        model.dismissError()

        _ = await model.addWord("Parakeet")
        let duplicate = await model.addWord("parakeet")
        XCTAssertFalse(duplicate)
        XCTAssertEqual(model.lastError, "“parakeet” is already in your list.")
        XCTAssertEqual(model.words.count, 1)

        let noExpansion = await model.addSnippet(trigger: "sig", expansion: " ")
        XCTAssertFalse(noExpansion)
        XCTAssertEqual(model.lastError, "A snippet needs both what you say and what Parakeet writes.")
    }

    func testCleanModeAppliesAStoredCustomWordEndToEndInTheFilePipeline() async throws {
        let store = FakeTextRulesStore()
        let editor = TextRulesViewModel(store: store)
        _ = await editor.addWord("Kenobi", replacement: "Obi-Wan")
        _ = await editor.addWord("there", replacement: "THERE")
        var word = try XCTUnwrap(editor.words.first { $0.word == "there" })
        word.isEnabled = false
        _ = await editor.update(word)

        var settings = TranscriptionSettings()
        settings.cleanupMode = .clean
        let h = try PipelineHarness(testCase: self, settings: settings, includeDiarizer: false)
        let pipeline = FileTranscriptionPipeline(
            paths: h.paths, store: h.store, normalizer: h.normalizer, speech: h.speech, diarizer: nil,
            scheduler: h.scheduler, settings: h.settings,
            customWords: { (try? await store.enabledCustomWords()) ?? [] },
            onProgress: { _, _ in })
        let id = try await pipeline.importFile(from: h.makeSourceFile())
        let row = await pipeline.process(id: id)

        XCTAssertEqual(row?.status, .completed)
        XCTAssertEqual(row?.rawTranscript, FakeSpeech.helloText)
        let clean = try XCTUnwrap(row?.cleanTranscript)
        XCTAssertTrue(clean.contains("Obi-Wan"), clean)
        XCTAssertFalse(clean.contains("THERE"), "a word turned off does not apply: \(clean)")
    }

    func testDictationPolishAppliesStoredWordsAndSnippets() async throws {
        let store = FakeTextRulesStore()
        let editor = TextRulesViewModel(store: store)
        _ = await editor.addWord("Kenobi", replacement: "Obi-Wan")
        _ = await editor.addSnippet(trigger: "General", expansion: "General Grievous")
        let rules = await DictationTextRules.enabled(in: store)
        XCTAssertEqual(rules.customWords.map(\.word), ["Kenobi"])
        XCTAssertEqual(rules.snippets.map(\.trigger), ["General"])

        let expected = TextRefinement().refine(
            rawText: FakeSpeech.helloText, mode: .clean, customWords: rules.customWords, snippets: rules.snippets)
        XCTAssertNotEqual(expected, FakeSpeech.helloText)
        XCTAssertTrue(expected?.contains("Obi-Wan") ?? false)
    }
}
