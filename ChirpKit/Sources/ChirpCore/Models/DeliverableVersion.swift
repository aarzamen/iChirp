import Foundation

// Plan 022 Step 4 (Edit by voice). Contract: spec/contracts/deliverables-v1.md (Versions). Stored by migration
// `v8-text-items` in the append-only `deliverable_versions` table.

/// One immutable text of a generated document. A document's versions are append-only: an edit by voice, a typed
/// instruction or a restore adds a version and makes it the document's current text; no version is ever changed or
/// removed (only deleting the document removes them). The document's text before its first change is version 1.
public struct DeliverableVersion: Codable, Sendable, Equatable, Identifiable {
    public enum Origin: String, Codable, Sendable, CaseIterable {
        /// The document's text before its first versioned change (as generated, or as the person edited it by then).
        case original
        /// The person's own edit in the editor, kept when a later change came.
        case handEdit
        /// A model rewrote it from a spoken instruction.
        case spokenEdit
        /// A model rewrote it from a typed instruction.
        case typedEdit
        /// An earlier version brought back (`restoredFrom`).
        case restore
    }

    public var id: UUID
    public var deliverableID: UUID
    /// 1, 2, 3, … per document.
    public var versionNumber: Int
    public var text: String
    public var origin: Origin
    /// The person's instruction for an edit (kept with the document on the phone; never logged, never in the ledger).
    public var instruction: String?
    /// For a restore: the version number brought back.
    public var restoredFrom: Int?
    /// The engine that wrote an edit (nil for the original, hand edits and restores).
    public var engineID: String?
    public var provider: String?
    public var model: String?
    public var locality: EngineLocality?
    /// The class the text had when it was stored.
    public var privacyClass: PrivacyClass
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        deliverableID: UUID,
        versionNumber: Int,
        text: String,
        origin: Origin,
        instruction: String? = nil,
        restoredFrom: Int? = nil,
        engineID: String? = nil,
        provider: String? = nil,
        model: String? = nil,
        locality: EngineLocality? = nil,
        privacyClass: PrivacyClass,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.deliverableID = deliverableID
        self.versionNumber = versionNumber
        self.text = text
        self.origin = origin
        self.instruction = instruction
        self.restoredFrom = restoredFrom
        self.engineID = engineID
        self.provider = provider
        self.model = model
        self.locality = locality
        self.privacyClass = privacyClass
        self.createdAt = createdAt
    }
}

/// What a new version carries; the store numbers it.
public struct DeliverableVersionDraft: Sendable, Equatable {
    public var text: String
    public var origin: DeliverableVersion.Origin
    public var instruction: String?
    public var restoredFrom: Int?
    public var engineID: String?
    public var provider: String?
    public var model: String?
    public var locality: EngineLocality?
    public var privacyClass: PrivacyClass
    public var createdAt: Date

    public init(
        text: String,
        origin: DeliverableVersion.Origin,
        instruction: String? = nil,
        restoredFrom: Int? = nil,
        engineID: String? = nil,
        provider: String? = nil,
        model: String? = nil,
        locality: EngineLocality? = nil,
        privacyClass: PrivacyClass,
        createdAt: Date = Date()
    ) {
        self.text = text
        self.origin = origin
        self.instruction = instruction
        self.restoredFrom = restoredFrom
        self.engineID = engineID
        self.provider = provider
        self.model = model
        self.locality = locality
        self.privacyClass = privacyClass
        self.createdAt = createdAt
    }
}

/// The document and its versions after an append.
public struct DeliverableVersionAppend: Sendable, Equatable {
    /// The document with its new current text.
    public var deliverable: Deliverable
    /// Every version, oldest first (the new one last).
    public var versions: [DeliverableVersion]

    public init(deliverable: Deliverable, versions: [DeliverableVersion]) {
        self.deliverable = deliverable
        self.versions = versions
    }
}
