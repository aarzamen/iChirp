import ChirpText
import GRDB
import XCTest

@testable import ChirpStore

/// M2 Step 5: migration `v4-dictation-text` and the GRDB custom words / snippets store (in-memory database).
final class GRDBTextRulesStoreTests: XCTestCase {
    private func makeStore() throws -> (GRDBTextRulesStore, DatabaseManager) {
        let database = try DatabaseManager.inMemory()
        return (GRDBTextRulesStore(database: database), database)
    }

    func testMigrationCreatesBothTablesWithUpstreamColumns() throws {
        let (_, database) = try makeStore()
        let (wordColumns, snippetColumns, applied) = try database.writer.read { db in
            (
                try db.columns(in: "custom_words").map(\.name),
                try db.columns(in: "text_snippets").map(\.name),
                try DatabaseManager.migrator.appliedIdentifiers(db)
            )
        }
        XCTAssertEqual(wordColumns, ["id", "word", "replacement", "source", "isEnabled", "createdAt", "updatedAt"])
        XCTAssertEqual(
            snippetColumns,
            ["id", "trigger", "expansion", "isEnabled", "useCount", "action", "createdAt", "updatedAt"])
        XCTAssertTrue(applied.contains("v4-dictation-text"), "\(applied)")
    }

    func testWordsSaveUpdateSortAndDelete() async throws {
        let (store, _) = try makeStore()
        var kube = CustomWord(word: "kubernetes", replacement: "Kubernetes")
        try await store.save(kube)
        try await store.save(CustomWord(word: "Aaron", isEnabled: false))
        var words = try await store.customWords()
        XCTAssertEqual(words.map(\.word), ["Aaron", "kubernetes"], "sorted case-insensitively")
        XCTAssertEqual(words.last?.replacement, "Kubernetes")
        XCTAssertFalse(words[0].isEnabled)

        kube.replacement = "K8s"
        try await store.save(kube)
        words = try await store.customWords()
        XCTAssertEqual(words.count, 2, "saving the same id updates it")
        XCTAssertEqual(words.first { $0.id == kube.id }?.replacement, "K8s")
        let enabled = try await store.enabledCustomWords()
        XCTAssertEqual(enabled.map(\.word), ["kubernetes"])

        try await store.deleteCustomWords(ids: [kube.id])
        words = try await store.customWords()
        XCTAssertEqual(words.map(\.word), ["Aaron"])
    }

    func testDuplicateWordIgnoringCaseThrowsDuplicate() async throws {
        let (store, _) = try makeStore()
        try await store.save(CustomWord(word: "Parakeet"))
        do {
            try await store.save(CustomWord(word: "PARAKEET"))
            XCTFail("expected a duplicate")
        } catch {
            XCTAssertEqual(error as? TextRulesStoreError, .duplicate("PARAKEET"))
        }
    }

    func testSnippetsRoundTripWithActionAndDuplicateTrigger() async throws {
        let (store, _) = try makeStore()
        let signature = TextSnippet(trigger: "my sig", expansion: "Best,\nA.", useCount: 2, action: .returnKey)
        try await store.save(signature)
        let loaded = try await store.snippets()
        XCTAssertEqual(loaded.map(\.id), [signature.id])
        XCTAssertEqual(loaded.first?.expansion, "Best,\nA.")
        XCTAssertEqual(loaded.first?.action, .returnKey)
        XCTAssertEqual(loaded.first?.useCount, 2)
        do {
            try await store.save(TextSnippet(trigger: "My Sig", expansion: "x"))
            XCTFail("expected a duplicate")
        } catch {
            XCTAssertEqual(error as? TextRulesStoreError, .duplicate("My Sig"))
        }
        try await store.deleteSnippets(ids: [signature.id])
        let none = try await store.snippets()
        XCTAssertEqual(none.count, 0)
    }

    // MARK: - Values a newer build wrote (review R1-2: a save never writes back the fallback it read)

    func testSavingAWordKeepsASourceANewerBuildWrote() async throws {
        let (store, database) = try makeStore()
        try await store.save(CustomWord(word: "Synthetic", replacement: "SYNTHETIC"))
        try await database.writer.write { db in try db.execute(sql: "UPDATE custom_words SET source = 'imported'") }
        let loadedWords = try await store.customWords()
        var word = try XCTUnwrap(loadedWords.first)
        XCTAssertEqual(word.source, .manual, "an unknown source reads as manual")

        word.isEnabled = false
        try await store.save(word)
        let kept = try await storedSource(database)
        XCTAssertEqual(kept, "imported", "an older build's save keeps the newer source")
        let saved = try await store.customWords()
        XCTAssertEqual(saved.first?.isEnabled, false, "the change itself lands")

        word.source = .learned
        try await store.save(word)
        let changed = try await storedSource(database)
        XCTAssertEqual(changed, "learned", "an explicit change to a known source lands")
    }

    func testSavingASnippetKeepsAnActionANewerBuildWrote() async throws {
        let (store, database) = try makeStore()
        try await store.save(TextSnippet(trigger: "synthetic sig", expansion: "Best"))
        try await database.writer.write { db in try db.execute(sql: "UPDATE text_snippets SET action = 'tab'") }
        let loadedSnippets = try await store.snippets()
        var snippet = try XCTUnwrap(loadedSnippets.first)
        XCTAssertNil(snippet.action, "an unknown action reads as none")

        snippet.expansion = "Best regards"
        try await store.save(snippet)
        let kept = try await storedAction(database)
        XCTAssertEqual(kept, "tab", "an older build's save keeps the newer action")
        let saved = try await store.snippets()
        XCTAssertEqual(saved.first?.expansion, "Best regards", "the change itself lands")

        snippet.action = .returnKey
        try await store.save(snippet)
        let changed = try await storedAction(database)
        XCTAssertEqual(changed, "return", "an explicit change to a known action lands")
    }

    private func storedSource(_ database: DatabaseManager) async throws -> String? {
        try await database.writer.read { db in try String.fetchOne(db, sql: "SELECT source FROM custom_words") }
    }

    private func storedAction(_ database: DatabaseManager) async throws -> String? {
        try await database.writer.read { db in try String.fetchOne(db, sql: "SELECT action FROM text_snippets") }
    }
}
