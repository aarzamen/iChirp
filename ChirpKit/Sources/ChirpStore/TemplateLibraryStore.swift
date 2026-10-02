// Semantics from MacParakeet (GPL-3.0): Sources/MacParakeetCore/Database/PromptEditingService.swift @ bbae9e0e — one
// save is one transaction, a version only when the text changes, soft delete and restore with a "(restored)" name; and
// Sources/MacParakeetCore/Database/QuickPromptRepository.swift @ bbae9e0e — reorder writes a bucket's full id list.
// Fresh implementation, not a line port.

import ChirpCore
import Foundation
import GRDB

/// The `prompts.isVisible` column. Added once, by the "v12-template-library" migration; never edited after it ships.
enum TemplateLibrarySchema {
    static func create(_ db: Database) throws {
        try db.alter(table: "prompts") { t in
            t.add(column: "isVisible", .boolean).notNull().defaults(to: true)
        }
    }
}

/// Plan 026: the person's own templates. Each method is one write transaction that re-checks the draft and the name's
/// uniqueness inside it, so two saves cannot take one name. Lookups use record APIs only (never raw SQL against a UUID;
/// see README). Logs carry ids, kinds and counts, never a name or instructions.
extension GRDBDeliverableStore: TemplateLibraryStoring {
    private static let libraryLogger = Log.logger("store")

    /// `sortOrder` of the first template of a section when a reorder writes it: Documents 0…n-1, Rewrites 1000+index.
    static func baseSortOrder(of category: PromptTemplate.Category) -> Int {
        switch category {
        case .deliverable: 0
        case .transform: 1_000
        }
    }

    public func fetchDeletedTemplates() async throws -> [PromptTemplate] {
        try await templatesDatabase.writer.read { db in
            try PromptRecord
                .filter(Column("deletedAt") != nil)
                .order(Column("deletedAt").desc, Column("name"))
                .fetchAll(db)
                .map { $0.toTemplate() }
        }
    }

    public func createUserTemplate(_ draft: TemplateDraft) async throws -> PromptTemplate {
        let template = try await templatesDatabase.writer.write { db in
            try Self.check(draft, db: db, excluding: nil)
            let now = Date()
            let promptID = UUID()
            let version = PromptVersion(
                promptID: promptID, versionNumber: 1, content: draft.cleanedInstructions, origin: .user,
                createdAt: now)
            let template = PromptTemplate(
                id: promptID, name: draft.cleanedName, category: draft.category,
                outputPrivacyClass: draft.outputPrivacyClass,
                sortOrder: try Self.nextSortOrder(db, category: draft.category, excluding: nil),
                isVisible: true, activeVersionID: version.id, createdAt: now, updatedAt: now)
            try PromptRecord(template).insert(db)
            try PromptVersionRecord(version).insert(db)
            return try PromptRecord.fetchOne(db, key: promptID)?.toTemplate() ?? template
        }
        Self.libraryLogger.info(
            """
            template_created id=\(template.id, privacy: .public) kind=\(template.category.rawValue, privacy: .public) \
            clinical=\(template.outputPrivacyClass == .clinical, privacy: .public)
            """)
        return template
    }

    public func updateUserTemplate(id: UUID, with draft: TemplateDraft) async throws -> PromptTemplate {
        let (template, newVersion) = try await templatesDatabase.writer.write { db -> (PromptTemplate, Bool) in
            var record = try Self.editableRecord(db, id: id)
            try Self.check(draft, db: db, excluding: id)
            let now = Date()
            let active = try PromptVersionRecord.fetchOne(db, key: record.activeVersionId)
            let instructions = draft.cleanedInstructions
            var newVersion = false
            if active?.content != instructions {
                let version = PromptVersion(
                    promptID: id, versionNumber: try Self.nextTemplateVersionNumber(db, promptID: id),
                    content: instructions,
                    origin: .user, createdAt: now)
                try PromptVersionRecord(version).insert(db)
                record.activeVersionId = version.id
                newVersion = true
            }
            if record.category != draft.category.rawValue {
                // A new kind moves it to the end of its new section.
                record.sortOrder = try Self.nextSortOrder(db, category: draft.category, excluding: id)
                record.category = draft.category.rawValue
            }
            record.name = draft.cleanedName
            record.outputPrivacyClass = draft.outputPrivacyClass?.rawValue
            record.updatedAt = now
            try record.update(db)
            return (record.toTemplate(), newVersion)
        }
        Self.libraryLogger.info(
            "template_updated id=\(id, privacy: .public) new_version=\(newVersion, privacy: .public)")
        return template
    }

    public func setTemplateVisible(id: UUID, isVisible: Bool) async throws {
        try await templatesDatabase.writer.write { db in
            var record = try Self.liveRecord(db, id: id)
            guard record.isVisible != isVisible else { return }
            record.isVisible = isVisible
            record.updatedAt = Date()
            try record.update(db)
        }
        Self.libraryLogger.info(
            "\(isVisible ? "template_shown" : "template_hidden", privacy: .public) id=\(id, privacy: .public)")
    }

    public func reorderTemplates(category: PromptTemplate.Category, ids: [UUID]) async throws {
        try await templatesDatabase.writer.write { db in
            let records =
                try PromptRecord
                .filter(Column("category") == category.rawValue && Column("deletedAt") == nil)
                .fetchAll(db)
            guard ids.count == records.count, Set(ids).count == ids.count,
                Set(ids) == Set(records.map(\.id))
            else { throw TemplateLibraryError.invalidOrder }
            let byID = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
            let base = Self.baseSortOrder(of: category)
            let now = Date()
            for (index, id) in ids.enumerated() {
                guard var record = byID[id], record.sortOrder != base + index else { continue }
                record.sortOrder = base + index
                record.updatedAt = now
                try record.update(db)
            }
        }
        Self.libraryLogger.info(
            "template_reordered kind=\(category.rawValue, privacy: .public) count=\(ids.count, privacy: .public)")
    }

    public func deleteUserTemplate(id: UUID) async throws {
        let deleted = try await templatesDatabase.writer.write { db -> Bool in
            guard var record = try PromptRecord.fetchOne(db, key: id) else {
                throw TemplateLibraryError.templateNotFound
            }
            guard !record.isBuiltIn else { throw TemplateLibraryError.builtInIsReadOnly }
            guard record.deletedAt == nil else { return false }
            let now = Date()
            record.deletedAt = now
            record.updatedAt = now
            try record.update(db)
            return true
        }
        if deleted { Self.libraryLogger.info("template_deleted id=\(id, privacy: .public)") }
    }

    public func restoreDeletedTemplate(id: UUID) async throws -> PromptTemplate {
        let (template, restored) = try await templatesDatabase.writer.write { db -> (PromptTemplate, Bool) in
            guard var record = try PromptRecord.fetchOne(db, key: id) else {
                throw TemplateLibraryError.templateNotFound
            }
            guard record.deletedAt != nil else { return (record.toTemplate(), false) }
            let taken = try Self.liveNames(db, excluding: id)
            record.name = TemplateNaming.restoredName(of: record.name, taken: taken)
            let category = PromptTemplate.Category(rawValue: record.category) ?? .deliverable
            record.sortOrder = try Self.nextSortOrder(db, category: category, excluding: id)
            record.deletedAt = nil
            record.updatedAt = Date()
            try record.update(db)
            return (record.toTemplate(), true)
        }
        if restored { Self.libraryLogger.info("template_restored id=\(id, privacy: .public)") }
        return template
    }

    public func countDeliverables(promptID: UUID) async throws -> Int {
        try await templatesDatabase.writer.read { db in
            try DeliverableRecord.filter(Column("promptId") == promptID).fetchCount(db)
        }
    }

    // MARK: - Helpers (inside the caller's transaction)

    /// The draft's own problem, with every other template that is not deleted counting as a taken name.
    private static func check(_ draft: TemplateDraft, db: Database, excluding id: UUID?) throws {
        if let problem = draft.problem(takenNames: try liveNames(db, excluding: id)) {
            throw TemplateLibraryError.problem(problem)
        }
    }

    private static func liveNames(_ db: Database, excluding id: UUID?) throws -> [String] {
        try PromptRecord.filter(Column("deletedAt") == nil).fetchAll(db)
            .filter { $0.id != id }
            .map(\.name)
    }

    /// A template that exists and is not deleted.
    private static func liveRecord(_ db: Database, id: UUID) throws -> PromptRecord {
        guard let record = try PromptRecord.fetchOne(db, key: id) else { throw TemplateLibraryError.templateNotFound }
        guard record.deletedAt == nil else { throw TemplateLibraryError.templateDeleted }
        return record
    }

    /// A template of the person's own that exists and is not deleted.
    private static func editableRecord(_ db: Database, id: UUID) throws -> PromptRecord {
        let record = try liveRecord(db, id: id)
        guard !record.isBuiltIn else { throw TemplateLibraryError.builtInIsReadOnly }
        return record
    }

    /// One past the highest `sortOrder` of the section's templates that are not deleted; the section's base when empty.
    private static func nextSortOrder(_ db: Database, category: PromptTemplate.Category, excluding id: UUID?) throws
        -> Int
    {
        let orders =
            try PromptRecord
            .filter(Column("category") == category.rawValue && Column("deletedAt") == nil)
            .fetchAll(db)
            .filter { $0.id != id }
            .map(\.sortOrder)
        return orders.max().map { $0 + 1 } ?? baseSortOrder(of: category)
    }

    private static func nextTemplateVersionNumber(_ db: Database, promptID: UUID) throws -> Int {
        let versions = try PromptVersionRecord.filter(Column("promptId") == promptID).fetchAll(db)
        return (versions.map(\.versionNumber).max() ?? 0) + 1
    }
}
