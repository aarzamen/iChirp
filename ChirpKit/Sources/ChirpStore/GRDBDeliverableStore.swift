// Semantics from MacParakeet (GPL-3.0): Sources/MacParakeetCore/Database/PromptRepository.swift (immutable versions,
// active-version pointer, built-in reconciliation by canonical key and revision) and LLMRunRepository @ bbae9e0e.
// Fresh implementation of ChirpCore's `DeliverableStoring` for iChirp's trimmed tables.

import ChirpCore
import Foundation
import GRDB

/// GRDB-backed `DeliverableStoring`. Every method runs its encoding and decoding inside GRDB's closures, never on the
/// caller's actor, and every lookup goes through record APIs (never raw SQL against a UUID; see README).
public final class GRDBDeliverableStore: DeliverableStoring {
    private let database: DatabaseManager
    private static let logger = Log.logger("store")

    public init(database: DatabaseManager) {
        self.database = database
    }

    /// Plan 022: the same database for the document versions (`DeliverableVersionStore.swift`).
    var versionsDatabase: DatabaseManager { database }
    /// Plan 023: the same database for the Library's lists of documents (`DeliverableListingStore.swift`).
    var listingDatabase: DatabaseManager { database }

    public enum StoreError: Error, Equatable, LocalizedError {
        case templateNotFound
        case emptyTemplate

        public var errorDescription: String? {
            switch self {
            case .templateNotFound: "This template no longer exists."
            case .emptyTemplate: "A template needs some text."
            }
        }
    }

    // MARK: - Templates

    public func installBuiltInTemplates(_ templates: [BuiltInPromptTemplate]) async throws {
        try await database.writer.write { db in
            let now = Date()
            for builtIn in templates {
                let existing = try PromptRecord.filter(Column("canonicalKey") == builtIn.canonicalKey).fetchOne(db)
                guard var record = existing else {
                    let version = PromptVersion(
                        promptID: builtIn.id, versionNumber: 1, content: builtIn.content, origin: .builtIn,
                        createdAt: now)
                    let template = PromptTemplate(
                        id: builtIn.id, name: builtIn.name, category: builtIn.category, isBuiltIn: true,
                        canonicalKey: builtIn.canonicalKey, canonicalRevision: builtIn.revision,
                        outputPrivacyClass: builtIn.outputPrivacyClass, sortOrder: builtIn.sortOrder,
                        activeVersionID: version.id, createdAt: now, updatedAt: now)
                    try PromptRecord(template).insert(db)
                    try PromptVersionRecord(version).insert(db)
                    continue
                }
                // A user edit or delete wins over a newer built-in definition.
                guard record.userCustomizedAt == nil, record.deletedAt == nil,
                    (record.canonicalRevision ?? 0) < builtIn.revision
                else { continue }
                let version = PromptVersion(
                    promptID: record.id, versionNumber: try Self.nextVersionNumber(db, promptID: record.id),
                    content: builtIn.content, origin: .systemUpdate, createdAt: now)
                try PromptVersionRecord(version).insert(db)
                record.activeVersionId = version.id
                record.canonicalRevision = builtIn.revision
                record.name = builtIn.name
                record.outputPrivacyClass = builtIn.outputPrivacyClass?.rawValue
                record.sortOrder = builtIn.sortOrder
                record.updatedAt = now
                try record.update(db)
            }
        }
    }

    public func fetchTemplates() async throws -> [PromptTemplate] {
        try await database.writer.read { db in
            try PromptRecord
                .filter(Column("deletedAt") == nil)
                .order(Column("sortOrder"), Column("name"))
                .fetchAll(db)
                .map { $0.toTemplate() }
        }
    }

    public func fetchTemplate(id: UUID) async throws -> PromptTemplate? {
        try await database.writer.read { db in
            try PromptRecord.fetchOne(db, key: id)?.toTemplate()
        }
    }

    public func fetchVersion(id: UUID) async throws -> PromptVersion? {
        try await database.writer.read { db in
            try PromptVersionRecord.fetchOne(db, key: id)?.toVersion()
        }
    }

    public func fetchVersions(promptID: UUID) async throws -> [PromptVersion] {
        try await database.writer.read { db in
            try PromptVersionRecord
                .filter(Column("promptId") == promptID)
                .order(Column("versionNumber"))
                .fetchAll(db)
                .map { $0.toVersion() }
        }
    }

    public func createTemplate(
        name: String,
        category: PromptTemplate.Category,
        content: String,
        outputPrivacyClass: PrivacyClass?
    ) async throws -> PromptTemplate {
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw StoreError.emptyTemplate }
        return try await database.writer.write { db in
            let now = Date()
            let promptID = UUID()
            let version = PromptVersion(promptID: promptID, versionNumber: 1, content: content, origin: .user)
            let maxOrder = try Int.fetchOne(db, sql: "SELECT MAX(sortOrder) FROM prompts") ?? 0
            let template = PromptTemplate(
                id: promptID, name: name, category: category, outputPrivacyClass: outputPrivacyClass,
                sortOrder: maxOrder + 1, activeVersionID: version.id, createdAt: now, updatedAt: now)
            try PromptRecord(template).insert(db)
            try PromptVersionRecord(version).insert(db)
            return try PromptRecord.fetchOne(db, key: promptID)?.toTemplate() ?? template
        }
    }

    public func addVersion(promptID: UUID, content: String) async throws -> PromptVersion {
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw StoreError.emptyTemplate }
        return try await database.writer.write { db in
            guard var record = try PromptRecord.fetchOne(db, key: promptID) else { throw StoreError.templateNotFound }
            let now = Date()
            let version = PromptVersion(
                promptID: promptID, versionNumber: try Self.nextVersionNumber(db, promptID: promptID),
                content: content, origin: .user, createdAt: now)
            try PromptVersionRecord(version).insert(db)
            record.activeVersionId = version.id
            if record.isBuiltIn { record.userCustomizedAt = now }
            record.updatedAt = now
            try record.update(db)
            return try PromptVersionRecord.fetchOne(db, key: version.id)?.toVersion() ?? version
        }
    }

    public func softDeleteTemplate(id: UUID) async throws {
        try await database.writer.write { db in
            guard var record = try PromptRecord.fetchOne(db, key: id) else { return }
            let now = Date()
            record.deletedAt = now
            if record.isBuiltIn { record.userCustomizedAt = now }
            record.updatedAt = now
            try record.update(db)
        }
    }

    private static func nextVersionNumber(_ db: Database, promptID: UUID) throws -> Int {
        let versions = try PromptVersionRecord.filter(Column("promptId") == promptID).fetchAll(db)
        return (versions.map(\.versionNumber).max() ?? 0) + 1
    }

    // MARK: - Deliverables

    public func insertDeliverable(_ deliverable: Deliverable) async throws {
        try await database.writer.write { db in
            try DeliverableRecord(deliverable).insert(db)
        }
    }

    public func fetchDeliverable(id: UUID) async throws -> Deliverable? {
        try await database.writer.read { db in
            try DeliverableRecord.fetchOne(db, key: id)?.toDeliverable()
        }
    }

    public func fetchDeliverables(transcriptionID: UUID) async throws -> [Deliverable] {
        try await database.writer.read { db in
            try DeliverableRecord
                .filter(Column("transcriptionId") == transcriptionID)
                .order(Column("createdAt").desc)
                .fetchAll(db)
                .map { $0.toDeliverable() }
        }
    }

    public func fetchRecentDeliverables(limit: Int) async throws -> [Deliverable] {
        try await database.writer.read { db in
            try DeliverableRecord
                .order(Column("createdAt").desc)
                .limit(max(0, limit))
                .fetchAll(db)
                .map { $0.toDeliverable() }
        }
    }

    public func updateDeliverableText(id: UUID, text: String) async throws -> Deliverable? {
        try await database.writer.write { db in
            guard var record = try DeliverableRecord.fetchOne(db, key: id) else { return nil }
            let now = Date()
            record.text = text
            record.editedAt = now
            record.updatedAt = now
            try record.update(db)
            return try DeliverableRecord.fetchOne(db, key: id)?.toDeliverable()
        }
    }

    public func raiseDeliverablePrivacyClass(transcriptionID: UUID, to privacyClass: PrivacyClass) async throws -> Int {
        try await database.writer.write { db in
            let records = try DeliverableRecord.filter(Column("transcriptionId") == transcriptionID).fetchAll(db)
            var changed = 0
            for var record in records {
                let current = PrivacyClass(rawValue: record.privacyClass) ?? .clinical
                // An unknown stored class is left as written (it already reads as the most protective class).
                guard PrivacyClass(rawValue: record.privacyClass) != nil,
                    current.stricter(privacyClass) != current
                else { continue }
                record.privacyClass = privacyClass.rawValue
                record.updatedAt = Date()
                try record.update(db)
                changed += 1
            }
            return changed
        }
    }

    public func deleteDeliverable(id: UUID) async throws {
        try await database.writer.write { db in
            _ = try DeliverableRecord.deleteOne(db, key: id)
        }
    }

    // MARK: - Run ledger

    public func recordRun(_ run: LanguageModelRun) async throws {
        try await database.writer.write { db in
            try LanguageModelRunRecord(run).insert(db)
        }
    }

    public func fetchRuns(limit: Int) async throws -> [LanguageModelRun] {
        try await database.writer.read { db in
            try LanguageModelRunRecord
                .order(Column("createdAt").desc)
                .limit(max(0, limit))
                .fetchAll(db)
                .map { $0.toRun() }
        }
    }
}
