import ChirpCore
import Foundation
import Synchronization
import XCTest

@testable import ChirpFeatures

/// A `LanguageModel` that records every request it receives and answers from a script. It behaves like a
/// conforming engine: deltas, then `.usage`, then `.finished`; honors cancellation.
final class RecordingLanguageModel: LanguageModel {
    let descriptor: EngineDescriptor
    let endpointHost: String?
    private let contextTokens: Int?
    private let state = Mutex(State())

    struct State {
        var requests: [GenerationRequest] = []
        var availability: LanguageModelAvailability = .available
        /// Consulted once per call, in order; when empty, `defaultReply` answers.
        var scripted: [Reply] = []
        /// Runs before each reply, with the number of the call (1-based); lets a test change state mid-run.
        var beforeReply: (@Sendable (Int) async -> Void)?
    }

    enum Reply: Sendable {
        case text(String)
        case error(LanguageModelError)
    }

    init(
        locality: EngineLocality,
        host: String? = nil,
        engineID: String? = nil,
        displayName: String = "Fake model",
        contextTokens: Int? = nil
    ) {
        descriptor = EngineDescriptor(
            id: engineID ?? "fake.\(locality.rawValue)", kind: .language, provider: "Fake", displayName: displayName,
            locality: locality, license: "Test")
        endpointHost = host
        self.contextTokens = contextTokens
    }

    var requests: [GenerationRequest] { state.withLock { $0.requests } }

    /// Everything this model was ever sent, for "did this text reach it?" assertions.
    var everythingReceived: String {
        requests.map { "\($0.system ?? "")\n\($0.prompt)" }.joined(separator: "\n")
    }

    func setAvailability(_ availability: LanguageModelAvailability) {
        state.withLock { $0.availability = availability }
    }

    func script(_ replies: [Reply]) {
        state.withLock { $0.scripted = replies }
    }

    func onEachCall(_ body: @escaping @Sendable (Int) async -> Void) {
        state.withLock { $0.beforeReply = body }
    }

    func contextWindowTokens() async -> Int? { contextTokens }

    func availability() async -> LanguageModelAvailability {
        state.withLock { $0.availability }
    }

    func generate(_ request: GenerationRequest) -> AsyncThrowingStream<GenerationEvent, Error> {
        let (call, reply, hook) = state.withLock { state -> (Int, Reply, (@Sendable (Int) async -> Void)?) in
            state.requests.append(request)
            let reply = state.scripted.isEmpty ? Self.defaultReply(request) : state.scripted.removeFirst()
            return (state.requests.count, reply, state.beforeReply)
        }
        return AsyncThrowingStream { continuation in
            let task = Task {
                await hook?(call)
                do {
                    try Task.checkCancellation()
                    switch reply {
                    case .text(let text):
                        let middle = text.index(text.startIndex, offsetBy: text.count / 2)
                        continuation.yield(.text(String(text[..<middle])))
                        continuation.yield(.text(String(text[middle...])))
                        continuation.yield(
                            .usage(GenerationUsage(promptTokens: 10, completionTokens: 5, model: "fake-1")))
                        continuation.yield(.finished)
                        continuation.finish()
                    case .error(let error):
                        continuation.finish(throwing: error)
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Final phases answer "Generated document."; map and condense phases answer short notes.
    static func defaultReply(_ request: GenerationRequest) -> Reply {
        if request.prompt.contains("<transcript_part") { return .text("notes for one part") }
        if request.system?.contains("group ") == true { return .text("condensed notes") }
        return .text("Generated document.")
    }
}

/// In-memory `DeliverableStoring` with the same rules as `GRDBDeliverableStore` that the service relies on.
actor FakeDeliverableStore: DeliverableStoring {
    private var templates: [UUID: PromptTemplate] = [:]
    private var versions: [UUID: PromptVersion] = [:]
    private(set) var deliverables: [UUID: Deliverable] = [:]
    private(set) var runs: [LanguageModelRun] = []

    func installBuiltInTemplates(_ builtIns: [BuiltInPromptTemplate]) async throws {
        for builtIn in builtIns where !templates.values.contains(where: { $0.canonicalKey == builtIn.canonicalKey }) {
            let version = PromptVersion(
                promptID: builtIn.id, versionNumber: 1, content: builtIn.content, origin: .builtIn)
            versions[version.id] = version
            templates[builtIn.id] = PromptTemplate(
                id: builtIn.id, name: builtIn.name, category: builtIn.category, isBuiltIn: true,
                canonicalKey: builtIn.canonicalKey, canonicalRevision: builtIn.revision,
                outputPrivacyClass: builtIn.outputPrivacyClass, sortOrder: builtIn.sortOrder,
                activeVersionID: version.id)
        }
    }

    func fetchTemplates() async throws -> [PromptTemplate] {
        templates.values.filter { $0.deletedAt == nil }.sorted { $0.sortOrder < $1.sortOrder }
    }

    func fetchTemplate(id: UUID) async throws -> PromptTemplate? { templates[id] }
    func fetchVersion(id: UUID) async throws -> PromptVersion? { versions[id] }

    func fetchVersions(promptID: UUID) async throws -> [PromptVersion] {
        versions.values.filter { $0.promptID == promptID }.sorted { $0.versionNumber < $1.versionNumber }
    }

    func createTemplate(
        name: String,
        category: PromptTemplate.Category,
        content: String,
        outputPrivacyClass: PrivacyClass?
    ) async throws -> PromptTemplate {
        let id = UUID()
        let version = PromptVersion(promptID: id, versionNumber: 1, content: content, origin: .user)
        versions[version.id] = version
        let template = PromptTemplate(
            id: id, name: name, category: category, outputPrivacyClass: outputPrivacyClass, activeVersionID: version.id)
        templates[id] = template
        return template
    }

    func addVersion(promptID: UUID, content: String) async throws -> PromptVersion {
        let number = try await fetchVersions(promptID: promptID).count + 1
        let version = PromptVersion(promptID: promptID, versionNumber: number, content: content, origin: .user)
        versions[version.id] = version
        templates[promptID]?.activeVersionID = version.id
        return version
    }

    func softDeleteTemplate(id: UUID) async throws { templates[id]?.deletedAt = Date() }

    func insertDeliverable(_ deliverable: Deliverable) async throws {
        try Task.checkCancellation()
        deliverables[deliverable.id] = deliverable
    }

    func fetchDeliverable(id: UUID) async throws -> Deliverable? { deliverables[id] }

    func fetchDeliverables(transcriptionID: UUID) async throws -> [Deliverable] {
        deliverables.values.filter { $0.transcriptionID == transcriptionID }.sorted { $0.createdAt > $1.createdAt }
    }

    func fetchRecentDeliverables(limit: Int) async throws -> [Deliverable] {
        Array(deliverables.values.sorted { $0.createdAt > $1.createdAt }.prefix(limit))
    }

    func updateDeliverableText(id: UUID, text: String) async throws -> Deliverable? {
        guard deliverables[id] != nil else { return nil }
        deliverables[id]?.text = text
        deliverables[id]?.editedAt = Date()
        return deliverables[id]
    }

    func raiseDeliverablePrivacyClass(transcriptionID: UUID, to privacyClass: PrivacyClass) async throws -> Int {
        var changed = 0
        for (id, item) in deliverables where item.transcriptionID == transcriptionID {
            let raised = item.privacyClass.stricter(privacyClass)
            if raised != item.privacyClass {
                deliverables[id]?.privacyClass = raised
                changed += 1
            }
        }
        return changed
    }

    func deleteDeliverable(id: UUID) async throws { deliverables[id] = nil }

    func recordRun(_ run: LanguageModelRun) async throws {
        try Task.checkCancellation()
        runs.append(run)
    }

    func fetchRuns(limit: Int) async throws -> [LanguageModelRun] { Array(runs.reversed().prefix(limit)) }

    // MARK: Plan 022 versions (the rules of `GRDBDeliverableStore.appendDeliverableVersion`)

    private(set) var documentVersions: [UUID: [DeliverableVersion]] = [:]

    func fetchDeliverableVersions(deliverableID: UUID) async throws -> [DeliverableVersion] {
        documentVersions[deliverableID] ?? []
    }

    func appendDeliverableVersion(_ draft: DeliverableVersionDraft, deliverableID: UUID) async throws
        -> DeliverableVersionAppend?
    {
        try Task.checkCancellation()
        guard var document = deliverables[deliverableID] else { return nil }
        var list = documentVersions[deliverableID] ?? []
        var next = (list.last?.versionNumber ?? 0) + 1
        if list.last?.text != document.text {
            list.append(
                DeliverableVersion(
                    deliverableID: deliverableID, versionNumber: next, text: document.text,
                    origin: list.isEmpty ? .original : .handEdit, privacyClass: document.privacyClass))
            next += 1
        }
        let raised = document.privacyClass.stricter(draft.privacyClass)
        list.append(
            DeliverableVersion(
                deliverableID: deliverableID, versionNumber: next, text: draft.text, origin: draft.origin,
                instruction: draft.instruction, restoredFrom: draft.restoredFrom, engineID: draft.engineID,
                provider: draft.provider, model: draft.model, locality: draft.locality, privacyClass: raised,
                createdAt: draft.createdAt))
        documentVersions[deliverableID] = list
        document.text = draft.text
        document.privacyClass = raised
        document.updatedAt = draft.createdAt
        deliverables[deliverableID] = document
        return DeliverableVersionAppend(deliverable: document, versions: list)
    }
}

extension FakeDeliverableStore: DeliverableVersionStoring {}

/// A settable clock for override expiry.
final class TestClock: Sendable {
    private let current = Mutex(Date(timeIntervalSinceReferenceDate: 800_000_000))
    var now: Date { current.withLock { $0 } }
    func advance(by seconds: TimeInterval) { current.withLock { $0 += seconds } }
}

/// A mutable routing policy, standing in for the provider settings the service reads at every check.
final class PolicyBox: Sendable {
    private let policy: Mutex<PrivacyRoutingPolicy>
    init(_ policy: PrivacyRoutingPolicy) { self.policy = Mutex(policy) }
    var current: PrivacyRoutingPolicy { policy.withLock { $0 } }
    func set(_ policy: PrivacyRoutingPolicy) { self.policy.withLock { $0 = policy } }
}

/// Every string field of a ledger row, for "no content in the ledger" assertions.
func stringFields(of run: LanguageModelRun) -> [String] {
    Mirror(reflecting: run).children.compactMap { child -> String? in
        if let string = child.value as? String { return string }
        if let optional = child.value as? String?, let string = optional { return string }
        return nil
    }
}
