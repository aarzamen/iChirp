// Semantics from MacParakeet (GPL-3.0): Sources/MacParakeetCore/Models/Prompt.swift, PromptVersion.swift and
// LLMRun.swift @ bbae9e0e — GRDB row mirrors of ChirpCore's template, version, deliverable and run types, kept in
// ChirpStore (like `TranscriptionRecord`) so ChirpCore has no GRDB dependency. Fresh implementation.

import ChirpCore
import Foundation
import GRDB

/// What an unknown privacy class reads as: the most protective class (same rule as `TranscriptionRecord`).
private let fallbackPrivacyClass = PrivacyClass.clinical
/// What an unknown locality reads as: cloud, the strictest routing.
private let fallbackLocality = EngineLocality.cloud

struct PromptRecord: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "prompts"

    var id: UUID
    var name: String
    var category: String
    var isBuiltIn: Bool
    var canonicalKey: String?
    var canonicalRevision: Int?
    var outputPrivacyClass: String?
    var sortOrder: Int
    var activeVersionId: UUID
    var userCustomizedAt: Date?
    var deletedAt: Date?
    var createdAt: Date
    var updatedAt: Date

    init(_ template: PromptTemplate) {
        id = template.id
        name = template.name
        category = template.category.rawValue
        isBuiltIn = template.isBuiltIn
        canonicalKey = template.canonicalKey
        canonicalRevision = template.canonicalRevision
        outputPrivacyClass = template.outputPrivacyClass?.rawValue
        sortOrder = template.sortOrder
        activeVersionId = template.activeVersionID
        userCustomizedAt = template.userCustomizedAt
        deletedAt = template.deletedAt
        createdAt = template.createdAt
        updatedAt = template.updatedAt
    }

    func toTemplate() -> PromptTemplate {
        PromptTemplate(
            id: id,
            name: name,
            category: PromptTemplate.Category(rawValue: category) ?? .deliverable,
            isBuiltIn: isBuiltIn,
            canonicalKey: canonicalKey,
            canonicalRevision: canonicalRevision,
            // An unknown stored class still raises the output (to the most protective class).
            outputPrivacyClass: outputPrivacyClass.map { PrivacyClass(rawValue: $0) ?? fallbackPrivacyClass },
            sortOrder: sortOrder,
            activeVersionID: activeVersionId,
            userCustomizedAt: userCustomizedAt,
            deletedAt: deletedAt,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}

struct PromptVersionRecord: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "prompt_versions"

    var id: UUID
    var promptId: UUID
    var versionNumber: Int
    var content: String
    var origin: String
    var createdAt: Date

    init(_ version: PromptVersion) {
        id = version.id
        promptId = version.promptID
        versionNumber = version.versionNumber
        content = version.content
        origin = version.origin.rawValue
        createdAt = version.createdAt
    }

    func toVersion() -> PromptVersion {
        PromptVersion(
            id: id, promptID: promptId, versionNumber: versionNumber, content: content,
            origin: PromptVersion.Origin(rawValue: origin) ?? .user, createdAt: createdAt)
    }
}

struct DeliverableRecord: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "deliverables"

    var id: UUID
    var transcriptionId: UUID
    var promptId: UUID?
    var promptVersionId: UUID?
    var title: String
    var engineId: String
    var provider: String
    var model: String?
    var locality: String
    var text: String
    var privacyClass: String
    var userNotes: String?
    var createdAt: Date
    var updatedAt: Date
    var editedAt: Date?

    init(_ deliverable: Deliverable) {
        id = deliverable.id
        transcriptionId = deliverable.transcriptionID
        promptId = deliverable.promptID
        promptVersionId = deliverable.promptVersionID
        title = deliverable.title
        engineId = deliverable.engineID
        provider = deliverable.provider
        model = deliverable.model
        locality = deliverable.locality.rawValue
        text = deliverable.text
        privacyClass = deliverable.privacyClass.rawValue
        userNotes = deliverable.userNotes
        createdAt = deliverable.createdAt
        updatedAt = deliverable.updatedAt
        editedAt = deliverable.editedAt
    }

    func toDeliverable() -> Deliverable {
        Deliverable(
            id: id,
            transcriptionID: transcriptionId,
            promptID: promptId,
            promptVersionID: promptVersionId,
            title: title,
            engineID: engineId,
            provider: provider,
            model: model,
            locality: EngineLocality(rawValue: locality) ?? fallbackLocality,
            text: text,
            privacyClass: PrivacyClass(rawValue: privacyClass) ?? fallbackPrivacyClass,
            userNotes: userNotes,
            createdAt: createdAt,
            updatedAt: updatedAt,
            editedAt: editedAt
        )
    }
}

/// The `llm_runs` row. Mirrors `LanguageModelRun` field for field; neither has a content field.
struct LanguageModelRunRecord: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "llm_runs"

    var id: UUID
    var feature: String
    var status: String
    var transcriptionId: UUID?
    var deliverableId: UUID?
    var promptVersionId: UUID?
    var engineId: String
    var provider: String
    var model: String?
    var locality: String
    var privacyClass: String
    var privacyOverride: Bool
    var errorType: String?
    var promptTokens: Int?
    var completionTokens: Int?
    var latencyMs: Int?
    var inputCharacters: Int
    var outputCharacters: Int?
    var callCount: Int
    var createdAt: Date

    init(_ run: LanguageModelRun) {
        id = run.id
        feature = run.feature.rawValue
        status = run.status.rawValue
        transcriptionId = run.transcriptionID
        deliverableId = run.deliverableID
        promptVersionId = run.promptVersionID
        engineId = run.engineID
        provider = run.provider
        model = run.model
        locality = run.locality.rawValue
        privacyClass = run.privacyClass.rawValue
        privacyOverride = run.privacyOverride
        errorType = run.errorType
        promptTokens = run.promptTokens
        completionTokens = run.completionTokens
        latencyMs = run.latencyMs
        inputCharacters = run.inputCharacters
        outputCharacters = run.outputCharacters
        callCount = run.callCount
        createdAt = run.createdAt
    }

    func toRun() -> LanguageModelRun {
        LanguageModelRun(
            id: id,
            feature: LanguageModelRun.Feature(rawValue: feature) ?? .deliverable,
            status: LanguageModelRun.Status(rawValue: status) ?? .failed,
            transcriptionID: transcriptionId,
            deliverableID: deliverableId,
            promptVersionID: promptVersionId,
            engineID: engineId,
            provider: provider,
            model: model,
            locality: EngineLocality(rawValue: locality) ?? fallbackLocality,
            privacyClass: PrivacyClass(rawValue: privacyClass) ?? fallbackPrivacyClass,
            privacyOverride: privacyOverride,
            errorType: errorType,
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            latencyMs: latencyMs,
            inputCharacters: inputCharacters,
            outputCharacters: outputCharacters,
            callCount: callCount,
            createdAt: createdAt
        )
    }
}
