import Foundation

// Contract: spec/contracts/deliverables-v1.md. Shapes follow upstream MacParakeet `Models/Prompt.swift`,
// `Models/PromptVersion.swift` and `Models/LLMRun.swift`, trimmed to what iChirp M4 stores, plus privacy classes.

/// A deliverable template (Summary, SOAP note, Polish, …). Its request text lives in immutable `PromptVersion`s; the
/// template points at the active one.
public struct PromptTemplate: Codable, Sendable, Equatable, Identifiable {
    public enum Category: String, Codable, Sendable, CaseIterable {
        /// A document made from a whole transcript (Summary, Meeting notes, SOAP note, …).
        case deliverable
        /// A rewrite of text (Polish, Distill, Decide, Brief).
        case transform
    }

    public var id: UUID
    public var name: String
    public var category: Category
    public var isBuiltIn: Bool
    /// Stable key of a built-in ("summary", "soap-note"); nil for user templates.
    public var canonicalKey: String?
    /// The built-in definition revision last applied to this row.
    public var canonicalRevision: Int?
    /// The class the output is raised to at least (SOAP note → `.clinical`). The run's routing class is the stricter
    /// of the transcript's class and this.
    public var outputPrivacyClass: PrivacyClass?
    public var sortOrder: Int
    /// The `PromptVersion` a run uses.
    public var activeVersionID: UUID
    /// Set when the user edits a built-in; later built-in revisions then leave it alone.
    public var userCustomizedAt: Date?
    /// Soft delete; the row and its versions stay so old deliverables keep their provenance.
    public var deletedAt: Date?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        category: Category,
        isBuiltIn: Bool = false,
        canonicalKey: String? = nil,
        canonicalRevision: Int? = nil,
        outputPrivacyClass: PrivacyClass? = nil,
        sortOrder: Int = 0,
        activeVersionID: UUID,
        userCustomizedAt: Date? = nil,
        deletedAt: Date? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.category = category
        self.isBuiltIn = isBuiltIn
        self.canonicalKey = canonicalKey
        self.canonicalRevision = canonicalRevision
        self.outputPrivacyClass = outputPrivacyClass
        self.sortOrder = sortOrder
        self.activeVersionID = activeVersionID
        self.userCustomizedAt = userCustomizedAt
        self.deletedAt = deletedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// One immutable request text of a template. Never updated after insert (the database rejects updates); an edit adds
/// a new version and moves the template's `activeVersionID`.
public struct PromptVersion: Codable, Sendable, Equatable, Identifiable {
    public enum Origin: String, Codable, Sendable, CaseIterable {
        case builtIn, user, systemUpdate
    }

    public var id: UUID
    public var promptID: UUID
    /// 1, 2, 3, … per template.
    public var versionNumber: Int
    /// The template text; may contain `{{transcript}}` and `{{userNotes}}`.
    public var content: String
    public var origin: Origin
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        promptID: UUID,
        versionNumber: Int,
        content: String,
        origin: Origin,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.promptID = promptID
        self.versionNumber = versionNumber
        self.content = content
        self.origin = origin
        self.createdAt = createdAt
    }
}

/// A built-in template definition shipped with the app. `id` and `canonicalKey` are reserved forever: never reuse
/// them for a different template. Bump `revision` when `content` changes.
public struct BuiltInPromptTemplate: Sendable, Equatable {
    public var id: UUID
    public var canonicalKey: String
    public var revision: Int
    public var name: String
    public var category: PromptTemplate.Category
    public var content: String
    public var outputPrivacyClass: PrivacyClass?
    public var sortOrder: Int

    public init(
        id: UUID,
        canonicalKey: String,
        revision: Int,
        name: String,
        category: PromptTemplate.Category,
        content: String,
        outputPrivacyClass: PrivacyClass? = nil,
        sortOrder: Int
    ) {
        self.id = id
        self.canonicalKey = canonicalKey
        self.revision = revision
        self.name = name
        self.category = category
        self.content = content
        self.outputPrivacyClass = outputPrivacyClass
        self.sortOrder = sortOrder
    }
}

/// A generated document linked to its source transcript. The transcript is never overwritten by generated text.
public struct Deliverable: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var transcriptionID: UUID
    /// The template and the exact version used; nil for Ask answers, or when a template was later removed.
    public var promptID: UUID?
    public var promptVersionID: UUID?
    /// Snapshot of the template name (or "Ask") at generation time.
    public var title: String
    /// `EngineDescriptor.id` of the engine that wrote it.
    public var engineID: String
    /// Provider display name at generation time, e.g. "Mac Studio (Ollama)".
    public var provider: String
    public var model: String?
    public var locality: EngineLocality
    /// The document. Editable by the user afterwards (`editedAt`).
    public var text: String
    /// Inherited: the stricter of the source's class and the template's `outputPrivacyClass`.
    public var privacyClass: PrivacyClass
    /// The notes supplied to the model for `{{userNotes}}`, when any.
    public var userNotes: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var editedAt: Date?

    public init(
        id: UUID = UUID(),
        transcriptionID: UUID,
        promptID: UUID?,
        promptVersionID: UUID?,
        title: String,
        engineID: String,
        provider: String,
        model: String?,
        locality: EngineLocality,
        text: String,
        privacyClass: PrivacyClass,
        userNotes: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date? = nil,
        editedAt: Date? = nil
    ) {
        self.id = id
        self.transcriptionID = transcriptionID
        self.promptID = promptID
        self.promptVersionID = promptVersionID
        self.title = title
        self.engineID = engineID
        self.provider = provider
        self.model = model
        self.locality = locality
        self.text = text
        self.privacyClass = privacyClass
        self.userNotes = userNotes
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.editedAt = editedAt
    }
}

/// One row of the run ledger (`llm_runs`). **Metadata only, by construction: there is no field that can hold
/// transcript text, prompts, notes, questions or output.** Ports upstream's `LLMRun` rule.
public struct LanguageModelRun: Codable, Sendable, Equatable, Identifiable {
    public enum Feature: String, Codable, Sendable, CaseIterable {
        case deliverable, ask
        /// M6a: one typed-decision call (`DecisionService`, spec/contracts/decision-model-plugin-v1.md).
        case decision
        /// Plan 022: one edit of a document from an instruction (`DeliverableService.edit`); the instruction is never
        /// stored here.
        case edit
    }

    public enum Status: String, Codable, Sendable, CaseIterable {
        case succeeded, failed, cancelled
        /// Privacy routing stopped the run before anything was sent.
        case refused
    }

    public var id: UUID
    public var feature: Feature
    public var status: Status
    public var transcriptionID: UUID?
    public var deliverableID: UUID?
    public var promptVersionID: UUID?
    public var engineID: String
    public var provider: String
    public var model: String?
    public var locality: EngineLocality
    /// The class the run was routed with.
    public var privacyClass: PrivacyClass
    /// True when a per-run clinical override was confirmed and used for this run.
    public var privacyOverride: Bool
    /// `LanguageModelError.kindName` or another content-free error name.
    public var errorType: String?
    public var promptTokens: Int?
    public var completionTokens: Int?
    public var latencyMs: Int?
    public var inputCharacters: Int
    public var outputCharacters: Int?
    /// Model calls made: 1 for a single pass, more for map-reduce.
    public var callCount: Int
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        feature: Feature,
        status: Status,
        transcriptionID: UUID?,
        deliverableID: UUID? = nil,
        promptVersionID: UUID? = nil,
        engineID: String,
        provider: String,
        model: String?,
        locality: EngineLocality,
        privacyClass: PrivacyClass,
        privacyOverride: Bool,
        errorType: String? = nil,
        promptTokens: Int? = nil,
        completionTokens: Int? = nil,
        latencyMs: Int? = nil,
        inputCharacters: Int,
        outputCharacters: Int? = nil,
        callCount: Int,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.feature = feature
        self.status = status
        self.transcriptionID = transcriptionID
        self.deliverableID = deliverableID
        self.promptVersionID = promptVersionID
        self.engineID = engineID
        self.provider = provider
        self.model = model
        self.locality = locality
        self.privacyClass = privacyClass
        self.privacyOverride = privacyOverride
        self.errorType = errorType
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.latencyMs = latencyMs
        self.inputCharacters = inputCharacters
        self.outputCharacters = outputCharacters
        self.callCount = callCount
        self.createdAt = createdAt
    }
}
