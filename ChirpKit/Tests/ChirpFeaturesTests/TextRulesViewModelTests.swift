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

    // MARK: - Learned rules (plan 025 B3)

    func testAddLearnedRuleSavesLearnedSource() async throws {
        let store = FakeTextRulesStore()
        let model = TextRulesViewModel(store: store)
        await model.load()
        let outcome = await model.addLearnedRule(word: " met for men ", replacement: " metformin ")
        XCTAssertEqual(outcome, .added)
        let stored = try await store.customWords()
        XCTAssertEqual(stored.map(\.word), ["met for men"])
        XCTAssertEqual(stored.map(\.replacement), ["metformin"])
        XCTAssertEqual(stored.map(\.source), [.learned])
        XCTAssertEqual(model.learnedRules.map(\.word), ["met for men"])
        XCTAssertEqual(model.manualWords.map(\.word), [])
        XCTAssertNil(model.lastError, "the outcome carries the message, not the editor's error")
    }

    func testDuplicateLearnedRuleReportsExisting() async throws {
        let store = FakeTextRulesStore()
        let model = TextRulesViewModel(store: store)
        _ = await model.addWord("Met For Men", replacement: "metformin")
        let outcome = await model.addLearnedRule(word: "met for men", replacement: "Metformin")
        XCTAssertEqual(outcome, .alreadyExists("“met for men” already has a rule in Settings → Text rules."))
        let stored = try await store.customWords()
        XCTAssertEqual(stored.count, 1)
        await store.fail(with: CocoaError(.fileWriteUnknown))
        let failed = await model.addLearnedRule(word: "smyth", replacement: "Smith")
        guard case .failed = failed else { return XCTFail("a store error is reported: \(failed)") }
    }

    func testManualWordsExcludeLearnedRules() async throws {
        let store = FakeTextRulesStore()
        let model = TextRulesViewModel(store: store)
        _ = await model.addWord("Kenobi", replacement: "Obi-Wan")
        _ = await model.addLearnedRule(word: "met for men", replacement: "metformin")
        XCTAssertEqual(model.manualWords.map(\.word), ["Kenobi"])
        XCTAssertEqual(model.learnedRules.map(\.word), ["met for men"])
        // Clean (files, dictation, meetings) and the accessor's context see manual words only.
        let rules = await DictationTextRules.enabled(in: store)
        XCTAssertEqual(rules.customWords.map(\.word), ["Kenobi"])
        let manual = try await store.enabledManualCustomWords()
        XCTAssertEqual(manual.map(\.word), ["Kenobi"])
        let learned = try await store.enabledLearnedRules()
        XCTAssertEqual(learned.map(\.word), ["met for men"])
        let context = await TranscriptTextContext.current(textRules: store, settings: InMemorySettingsStore())
        XCTAssertEqual(context.customWords.map(\.word), ["Kenobi"])
        // A turned-off rule is not applied.
        var rule = try XCTUnwrap(model.learnedRules.first)
        rule.isEnabled = false
        _ = await model.update(rule)
        let enabled = try await store.enabledLearnedRules()
        XCTAssertEqual(enabled.map(\.word), [])
    }

    // MARK: - Fix round 1

    /// C1: a learned rule may not contain a number, in what it finds or what it writes (a dose is never changed
    /// automatically); M4: it needs a replacement. Both on add and on edit.
    func testLearnedRulesCannotContainNumbersOrLoseTheirReplacement() async throws {
        let store = FakeTextRulesStore()
        let model = TextRulesViewModel(store: store)
        let dose = await model.addLearnedRule(word: "0.5 mg", replacement: "5 mg")
        XCTAssertEqual(dose, .refused("Rules can’t contain numbers, so a dose is never changed automatically."))
        let count = await model.addLearnedRule(word: "twice", replacement: "2 times")
        XCTAssertEqual(count, .refused("Rules can’t contain numbers, so a dose is never changed automatically."))
        let stored = try await store.customWords()
        XCTAssertEqual(stored.count, 0)

        _ = await model.addLearnedRule(word: "met for men", replacement: "metformin")
        var rule = try XCTUnwrap(model.learnedRules.first)
        rule.replacement = "metformin 500"
        let numbered = await model.update(rule)
        XCTAssertFalse(numbered)
        XCTAssertEqual(model.lastError, "Rules can’t contain numbers, so a dose is never changed automatically.")
        model.dismissError()
        rule.replacement = "  "
        let blank = await model.update(rule)
        XCTAssertFalse(blank)
        XCTAssertEqual(model.lastError, "A fix needs what Parakeet writes instead. To stop it, delete the rule.")
        let kept = try await store.customWords()
        XCTAssertEqual(kept.map(\.replacement), ["metformin"])
        // Manual words may still hold numbers ("COVID-19").
        let manual = await model.addWord("covid 19", replacement: "COVID-19")
        XCTAssertTrue(manual)
    }
}
