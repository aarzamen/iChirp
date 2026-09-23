// Fresh implementation for iChirp (plan 022 Step 4): append-only versions of generated documents, in the same
// transactional style as `prompt_versions` (SQLite triggers make the rows immutable, not just the repository).

import ChirpCore
import Foundation
import GRDB

/// The `deliverable_versions` table. Created once, by the "v8-text-items" migration; never edited after it ships.
enum DeliverableVersionSchema {
    static func create(_ db: Database) throws {
        try db.create(table: "deliverable_versions") { t in
            t.column("id", .text).primaryKey()
            // Deleting the document (an explicit user flow, or deleting its transcript) deletes its versions with it.
            t.column("deliverableId", .text).notNull().references("deliverables", onDelete: .cascade)
            t.column("versionNumber", .integer).notNull()
            t.column("text", .text).notNull()
            t.column("origin", .text).notNull()
            t.column("instruction", .text)
            t.column("restoredFrom", .integer)
            t.column("engineId", .text)
            t.column("provider", .text)
            t.column("model", .text)
            t.column("locality", .text)
            t.column("privacyClass", .text).notNull()
            t.column("createdAt", .datetime).notNull()
            t.uniqueKey(["deliverableId", "versionNumber"])
        }
        try db.create(
            index: "idx_deliverable_versions_deliverable", on: "deliverable_versions", columns: ["deliverableId"])
        // Append-only: a version is never changed, and never deleted while its document exists (the cascade from a
        // deleted document is the only way a version goes).
        try db.execute(
            sql: """
                CREATE TRIGGER deliverable_versions_immutable_update BEFORE UPDATE ON deliverable_versions
                BEGIN SELECT RAISE(ABORT, 'deliverable_versions rows are immutable'); END;
                CREATE TRIGGER deliverable_versions_immutable_delete BEFORE DELETE ON deliverable_versions
                WHEN EXISTS (SELECT 1 FROM deliverables WHERE id = OLD.deliverableId)
                BEGIN SELECT RAISE(ABORT, 'deliverable_versions rows are append-only'); END;
                """)
    }
}

/// One `deliverable_versions` row.
struct DeliverableVersionRecord: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "deliverable_versions"

    var id: UUID
    var deliverableId: UUID
    var versionNumber: Int
    var text: String
    var origin: String
    var instruction: String?
    var restoredFrom: Int?
    var engineId: String?
    var provider: String?
    var model: String?
    var locality: String?
    var privacyClass: String
    var createdAt: Date

    init(_ version: DeliverableVersion) {
        id = version.id
        deliverableId = version.deliverableID
        versionNumber = version.versionNumber
        text = version.text
        origin = version.origin.rawValue
        instruction = version.instruction
        restoredFrom = version.restoredFrom
        engineId = version.engineID
        provider = version.provider
        model = version.model
        locality = version.locality?.rawValue
        privacyClass = version.privacyClass.rawValue
        createdAt = version.createdAt
    }

    func toVersion() -> DeliverableVersion {
        DeliverableVersion(
            id: id, deliverableID: deliverableId, versionNumber: versionNumber, text: text,
            // An origin a newer build wrote reads as a hand edit (the most neutral label); the text is what matters.
            origin: DeliverableVersion.Origin(rawValue: origin) ?? .handEdit,
            instruction: instruction, restoredFrom: restoredFrom, engineID: engineId, provider: provider, model: model,
            locality: locality.map { EngineLocality(rawValue: $0) ?? .cloud },
            // An unknown class reads as the most protective one.
            privacyClass: PrivacyClass(rawValue: privacyClass) ?? .clinical, createdAt: createdAt)
    }
}

extension GRDBDeliverableStore: DeliverableVersionStoring {
    public func fetchDeliverableVersions(deliverableID: UUID) async throws -> [DeliverableVersion] {
        try await versionsDatabase.writer.read { db in
            try DeliverableVersionRecord
                .filter(Column("deliverableId") == deliverableID)
                .order(Column("versionNumber"))
                .fetchAll(db)
                .map { $0.toVersion() }
        }
    }

    public func appendDeliverableVersion(_ draft: DeliverableVersionDraft, deliverableID: UUID) async throws
        -> DeliverableVersionAppend?
    {
        try await versionsDatabase.writer.write { db in
            guard var document = try DeliverableRecord.fetchOne(db, key: deliverableID) else { return nil }
            let existing =
                try DeliverableVersionRecord
                .filter(Column("deliverableId") == deliverableID)
                .order(Column("versionNumber"))
                .fetchAll(db)
            var next = (existing.last?.versionNumber ?? 0) + 1
            let documentClass = PrivacyClass(rawValue: document.privacyClass) ?? .clinical
            // Keep what the document says now before anything replaces it: the first time as the original, later as
            // the person's own edit in the editor.
            if existing.last?.text != document.text {
                let kept = DeliverableVersion(
                    deliverableID: deliverableID, versionNumber: next, text: document.text,
                    origin: existing.isEmpty ? .original : .handEdit,
                    engineID: existing.isEmpty ? document.engineId : nil,
                    provider: existing.isEmpty ? document.provider : nil,
                    model: existing.isEmpty ? document.model : nil,
                    locality: existing.isEmpty ? EngineLocality(rawValue: document.locality) : nil,
                    privacyClass: documentClass,
                    createdAt: existing.isEmpty ? document.createdAt : (document.editedAt ?? draft.createdAt))
                try DeliverableVersionRecord(kept).insert(db)
                next += 1
            }
            let raised = documentClass.stricter(draft.privacyClass)
            let version = DeliverableVersion(
                deliverableID: deliverableID, versionNumber: next, text: draft.text, origin: draft.origin,
                instruction: draft.instruction, restoredFrom: draft.restoredFrom, engineID: draft.engineID,
                provider: draft.provider, model: draft.model, locality: draft.locality, privacyClass: raised,
                createdAt: draft.createdAt)
            try DeliverableVersionRecord(version).insert(db)
            document.text = draft.text
            document.privacyClass = raised.rawValue
            document.updatedAt = draft.createdAt
            try document.update(db)
            let versions =
                try DeliverableVersionRecord
                .filter(Column("deliverableId") == deliverableID)
                .order(Column("versionNumber"))
                .fetchAll(db)
                .map { $0.toVersion() }
            guard let stored = try DeliverableRecord.fetchOne(db, key: deliverableID)?.toDeliverable() else {
                return nil
            }
            return DeliverableVersionAppend(deliverable: stored, versions: versions)
        }
    }
}
