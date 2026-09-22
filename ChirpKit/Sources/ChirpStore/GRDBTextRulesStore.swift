// Ported from MacParakeet (GPL-3.0): Sources/MacParakeetCore/Database/CustomWordRepository.swift @ bbae9e0e
// Changes: custom words and text snippets (upstream `TextSnippetRepository.swift`) behind one async
// `ChirpText.TextRulesStoring`, with ChirpStore-private records instead of GRDB conformances on the ChirpText models;
// a unique-index violation becomes `TextRulesStoreError.duplicate`.

import ChirpText
import Foundation
import GRDB

/// GRDB-backed `TextRulesStoring` over the `custom_words` and `text_snippets` tables (migration `v4-dictation-text`).
public final class GRDBTextRulesStore: TextRulesStoring {
    private let database: DatabaseManager

    public init(database: DatabaseManager) {
        self.database = database
    }

    public func customWords() async throws -> [CustomWord] {
        try await database.writer.read { db in
            try CustomWordRecord.order(Column("word").collating(.localizedCaseInsensitiveCompare)).fetchAll(db)
                .map(\.model)
        }
    }

    public func save(_ word: CustomWord) async throws {
        let record = CustomWordRecord(word)
        try await Self.mappingDuplicate(word.word) {
            try await self.database.writer.write { db in try record.save(db) }
        }
    }

    public func deleteCustomWords(ids: Set<UUID>) async throws {
        guard !ids.isEmpty else { return }
        _ = try await database.writer.write { db in try CustomWordRecord.deleteAll(db, keys: Array(ids)) }
    }

    public func snippets() async throws -> [TextSnippet] {
        try await database.writer.read { db in
            try TextSnippetRecord.order(Column("trigger").collating(.localizedCaseInsensitiveCompare)).fetchAll(db)
                .map(\.model)
        }
    }

    public func save(_ snippet: TextSnippet) async throws {
        let record = TextSnippetRecord(snippet)
        try await Self.mappingDuplicate(snippet.trigger) {
            try await self.database.writer.write { db in try record.save(db) }
        }
    }

    public func deleteSnippets(ids: Set<UUID>) async throws {
        guard !ids.isEmpty else { return }
        _ = try await database.writer.write { db in try TextSnippetRecord.deleteAll(db, keys: Array(ids)) }
    }

    private static func mappingDuplicate(_ text: String, _ body: () async throws -> Void) async throws {
        do {
            try await body()
        } catch let error as DatabaseError where error.extendedResultCode == .SQLITE_CONSTRAINT_UNIQUE {
            throw TextRulesStoreError.duplicate(text)
        }
    }
}

/// The `custom_words` row (upstream columns).
struct CustomWordRecord: Codable, Sendable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "custom_words"

    var id: UUID
    var word: String
    var replacement: String?
    var source: String
    var isEnabled: Bool
    var createdAt: Date
    var updatedAt: Date

    init(_ word: CustomWord) {
        id = word.id
        self.word = word.word
        replacement = word.replacement
        source = word.source.rawValue
        isEnabled = word.isEnabled
        createdAt = word.createdAt
        updatedAt = word.updatedAt
    }

    var model: CustomWord {
        CustomWord(
            id: id, word: word, replacement: replacement, source: CustomWord.Source(rawValue: source) ?? .manual,
            isEnabled: isEnabled, createdAt: createdAt, updatedAt: updatedAt)
    }
}

/// The `text_snippets` row (upstream columns, including v0.6's `action`).
struct TextSnippetRecord: Codable, Sendable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "text_snippets"

    var id: UUID
    var trigger: String
    var expansion: String
    var isEnabled: Bool
    var useCount: Int
    var action: String?
    var createdAt: Date
    var updatedAt: Date

    init(_ snippet: TextSnippet) {
        id = snippet.id
        trigger = snippet.trigger
        expansion = snippet.expansion
        isEnabled = snippet.isEnabled
        useCount = snippet.useCount
        action = snippet.action?.rawValue
        createdAt = snippet.createdAt
        updatedAt = snippet.updatedAt
    }

    var model: TextSnippet {
        TextSnippet(
            id: id, trigger: trigger, expansion: expansion, isEnabled: isEnabled, useCount: useCount,
            action: action.flatMap(KeyAction.init(rawValue:)), createdAt: createdAt, updatedAt: updatedAt)
    }
}
