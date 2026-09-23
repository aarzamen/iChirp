// Semantics from MacParakeet (GPL-3.0): Sources/MacParakeetCore/Services/LLM/LLMService.swift and LLMRunRecorder.swift
// @ bbae9e0e — one service between features and the LLM client, a metadata-only run ledger written for every run, no
// content in logs. Fresh implementation for iChirp: privacy routing with per-run override tokens (ADR-002), the
// template version and privacy class recorded with each deliverable, and map-reduce instead of truncation.

import ChirpCore
import ChirpText
import Foundation

/// Where one run would send content.
public struct ModelRoute: Sendable, Equatable {
    public var transcriptionID: UUID
    public var engineID: String
    /// `descriptor.displayName`, e.g. "Mac Studio (Ollama)".
    public var providerName: String
    public var locality: EngineLocality
    public var host: String?
    /// The class the run is routed with: the transcript's, raised by the template's output class.
    public var privacyClass: PrivacyClass

    /// The same destination and content class (the provider's display name may change).
    func matches(_ other: ModelRoute) -> Bool {
        transcriptionID == other.transcriptionID && engineID == other.engineID && locality == other.locality
            && host == other.host && privacyClass == other.privacyClass
    }
}

/// A question the UI must put to the user before clinical content may go to `route`.
public struct PrivacyOverrideRequest: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let route: ModelRoute

    /// "Send this clinical transcript to Claude?"
    public var title: String {
        "Send this clinical transcript to \(route.providerName)?"
    }

    public var message: String {
        switch route.locality {
        case .cloud:
            "It will leave this iPhone and go to \(route.providerName) over the internet. This applies to this run only."
        case .localNetwork:
            "It will go to \(route.host ?? "a computer") on your network, which you have not marked as trusted. "
                + "This applies to this run only."
        case .onDevice:
            "It stays on this iPhone."
        }
    }
}

/// Proof that the user confirmed one `PrivacyOverrideRequest`. Only `DeliverableService.confirmOverride` creates it;
/// it is bound to that route, works for one run, and expires after `DeliverableService.overrideLifetime`.
public struct PrivacyOverride: Sendable, Equatable {
    public let id: UUID
    public let requestID: UUID
    public let route: ModelRoute
    public let confirmedAt: Date

    init(requestID: UUID, route: ModelRoute, confirmedAt: Date) {
        id = UUID()
        self.requestID = requestID
        self.route = route
        self.confirmedAt = confirmedAt
    }
}

/// The router's answer before a run.
public enum RouteDecision: Sendable, Equatable {
    case allowed(ModelRoute)
    /// Clinical content to a cloud or untrusted LAN engine: ask the user, then pass the token to the run.
    case needsOverride(PrivacyOverrideRequest)
}

public enum DeliverableError: Error, Equatable, LocalizedError {
    case transcriptNotFound
    case emptyTranscript
    case templateNotFound
    /// Nothing was sent. Show `request.title` / `request.message`; on confirm, run again with the token.
    case privacyOverrideRequired(PrivacyOverrideRequest)
    /// `confirmOverride` was given a request this service did not issue, or one already answered.
    case unknownOverrideRequest
    case modelUnavailable(LanguageModelUnavailableReason)
    /// Even split into parts, the transcript cannot fit this model. Nothing was stored; nothing was truncated.
    case transcriptTooLong
    /// The model finished without any text.
    case emptyResult
    /// Plan 022 (Edit by voice): the document no longer exists.
    case documentNotFound
    /// The document has no text to edit.
    case emptyDocument
    /// The instruction was empty (nothing was sent).
    case emptyInstruction
    /// The document is longer than this model can read and write back in one pass. Nothing was sent or stored.
    case documentTooLongToEdit
    /// This build's document store keeps no versions, so an edit could not be kept without overwriting.
    case versionsUnavailable

    public var errorDescription: String? {
        switch self {
        case .transcriptNotFound: "This transcript no longer exists."
        case .emptyTranscript: "This transcript has no text yet."
        case .templateNotFound: "This template no longer exists."
        case .privacyOverrideRequired(let request): request.title
        case .unknownOverrideRequest: "That confirmation has expired. Start the run again."
        case .modelUnavailable(let reason): reason.message
        case .transcriptTooLong:
            "This transcript is too long for this model, even split into parts. Nothing was cut or saved. "
                + "Choose a model with a larger context."
        case .emptyResult: "The model returned no text."
        case .documentNotFound: "This document no longer exists."
        case .emptyDocument: "This document has no text to edit."
        case .emptyInstruction: "Say or type what to change first."
        case .documentTooLongToEdit:
            "This document is too long for this model to rewrite in one pass. Nothing was sent or changed. Choose a "
                + "model with a larger context, or edit it by hand."
        case .versionsUnavailable: "This document’s versions can’t be kept, so nothing was changed."
        }
    }

    /// Content-free name for logs and the run ledger.
    var kindName: String {
        switch self {
        case .transcriptNotFound: "transcript_not_found"
        case .emptyTranscript: "empty_transcript"
        case .templateNotFound: "template_not_found"
        case .privacyOverrideRequired: "privacy_override_required"
        case .unknownOverrideRequest: "unknown_override_request"
        case .modelUnavailable: "model_unavailable"
        case .transcriptTooLong: "transcript_too_long"
        case .emptyResult: "empty_result"
        case .documentNotFound: "document_not_found"
        case .emptyDocument: "empty_document"
        case .emptyInstruction: "empty_instruction"
        case .documentTooLongToEdit: "document_too_long_to_edit"
        case .versionsUnavailable: "versions_unavailable"
        }
    }
}

/// Progress and results of one run.
public enum DeliverableRunEvent: Sendable, Equatable {
    /// Routing passed; nothing has been sent yet.
    case routed(ModelRoute, privacyOverrideUsed: Bool)
    /// `.writing` starts the final text: the UI clears its buffer and appends the `.text` deltas that follow.
    case step(DeliverableRunStep)
    case text(String)
    case completed(Deliverable)
    case answered(AskAnswer)
}

public enum DeliverableRunStep: Sendable, Equatable {
    case reading(part: Int, of: Int)
    case combining(level: Int)
    case writing
}

/// An Ask answer with the citations that point at real segments.
public struct AskAnswer: Sendable, Equatable {
    public var text: String
    public var citations: [TranscriptCitation]
    public var route: ModelRoute
}

/// **The only path from a transcript to a `LanguageModel`.** Every run:
/// 1. reads the transcript as stored now and routes it (`PrivacyRoutingPolicy.allows`, with the engine's real host)
///    with its `EffectivePrivacyClass` (a clinical deliverable of a personal transcript makes it clinical);
/// 2. refuses clinical content to a cloud or untrusted LAN engine unless it holds a valid, unused `PrivacyOverride`
///    for exactly that route, and logs the override without content;
/// 3. checks the route again before every later model call, against the effective class stored at that moment;
/// 4. splits long input (map-reduce) and never truncates;
/// 5. stores the result as a new `Deliverable` (never touching the transcript) with the template version and class;
/// 6. writes one metadata-only `LanguageModelRun`, whatever the outcome.
public actor DeliverableService {
    /// How long a confirmed override stays usable.
    public static let overrideLifetime: TimeInterval = 10 * 60

    private let transcripts: any TranscriptionStoring
    private let deliverables: any DeliverableStoring
    private let routingPolicy: @Sendable () -> PrivacyRoutingPolicy
    private let now: @Sendable () -> Date
    private let logger = Log.logger("deliverables")
    private let privacyLogger = Log.logger("privacy")

    private var pendingRequests: [UUID: PrivacyOverrideRequest] = [:]
    private var unusedOverrides: [UUID: PrivacyOverride] = [:]

    /// - Parameter routingPolicy: read at every check, so un-trusting a host stops the next call of a running job.
    public init(
        transcripts: any TranscriptionStoring,
        deliverables: any DeliverableStoring,
        routingPolicy: @escaping @Sendable () -> PrivacyRoutingPolicy,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.transcripts = transcripts
        self.deliverables = deliverables
        self.routingPolicy = routingPolicy
        self.now = now
    }

    // MARK: - Templates and classes

    public func installBuiltInTemplates() async throws {
        try await deliverables.installBuiltInTemplates(BuiltInTemplates.all)
    }

    /// Sets a transcript's class and raises (never lowers) its deliverables to at least that class.
    @discardableResult
    public func setPrivacyClass(_ privacyClass: PrivacyClass, transcriptionID: UUID) async throws -> Transcription? {
        guard let updated = try await transcripts.updatePrivacyClass(id: transcriptionID, privacyClass: privacyClass)
        else { return nil }
        _ = try await deliverables.raiseDeliverablePrivacyClass(transcriptionID: transcriptionID, to: privacyClass)
        logger.info(
            "privacy_class_set transcription=\(transcriptionID, privacy: .public) class=\(privacyClass.rawValue, privacy: .public)"
        )
        return updated
    }

    // MARK: - Routing

    /// What running `templateID` (nil for Ask) on the transcript with `model` needs. Sends nothing.
    public func route(transcriptionID: UUID, templateID: UUID?, model: any LanguageModel) async throws -> RouteDecision
    {
        guard let transcription = try await transcripts.fetch(id: transcriptionID) else {
            throw DeliverableError.transcriptNotFound
        }
        var outputClass: PrivacyClass?
        if let templateID {
            guard let template = try await deliverables.fetchTemplate(id: templateID) else {
                throw DeliverableError.templateNotFound
            }
            outputClass = template.outputPrivacyClass
        }
        let effective = try await EffectivePrivacyClass.of(transcription, in: deliverables)
        let route = makeRoute(transcription, baseClass: effective, outputClass: outputClass, model: model)
        if isAllowed(route, model: model, override: false) { return .allowed(route) }
        return .needsOverride(issueRequest(for: route))
    }

    /// The user confirmed `request`: returns the single-use token for that route.
    public func confirmOverride(_ request: PrivacyOverrideRequest) throws -> PrivacyOverride {
        guard pendingRequests.removeValue(forKey: request.id) != nil else {
            throw DeliverableError.unknownOverrideRequest
        }
        let token = PrivacyOverride(requestID: request.id, route: request.route, confirmedAt: now())
        unusedOverrides[token.id] = token
        privacyLogger.notice(
            "privacy_override_confirmed transcription=\(request.route.transcriptionID, privacy: .public) engine=\(request.route.engineID, privacy: .public) locality=\(request.route.locality.rawValue, privacy: .public)"
        )
        return token
    }

    /// - Parameter baseClass: the transcript's `EffectivePrivacyClass` as stored now (its own class, raised by any
    ///   stricter deliverable made from it).
    private func makeRoute(
        _ transcription: Transcription,
        baseClass: PrivacyClass,
        outputClass: PrivacyClass?,
        model: any LanguageModel
    ) -> ModelRoute {
        ModelRoute(
            transcriptionID: transcription.id,
            engineID: model.descriptor.id,
            providerName: model.descriptor.displayName,
            locality: model.descriptor.locality,
            host: model.endpointHost?.lowercased(),
            privacyClass: baseClass.stricter(outputClass)
        )
    }

    private func isAllowed(_ route: ModelRoute, model: any LanguageModel, override: Bool) -> Bool {
        routingPolicy().allows(model.descriptor, for: route.privacyClass, host: route.host, userOverride: override)
    }

    private func issueRequest(for route: ModelRoute) -> PrivacyOverrideRequest {
        let request = PrivacyOverrideRequest(id: UUID(), route: route)
        pendingRequests[request.id] = request
        return request
    }

    /// Uses up `token` if it is unused, unexpired and for exactly `route`. A token is gone after one attempt.
    private func consume(_ token: PrivacyOverride?, for route: ModelRoute) -> Bool {
        guard let token else { return false }
        guard let stored = unusedOverrides.removeValue(forKey: token.id) else {
            privacyLogger.notice("privacy_override_rejected reason=used_or_unknown")
            return false
        }
        guard stored.route.matches(route) else {
            privacyLogger.notice("privacy_override_rejected reason=route_mismatch")
            return false
        }
        guard now().timeIntervalSince(stored.confirmedAt) <= Self.overrideLifetime else {
            privacyLogger.notice("privacy_override_rejected reason=expired")
            return false
        }
        return true
    }

    // MARK: - Runs

    /// Runs a template on a transcript and stores the result as a deliverable.
    public nonisolated func generate(
        templateID: UUID,
        transcriptionID: UUID,
        userNotes: String? = nil,
        model: any LanguageModel,
        override: PrivacyOverride? = nil
    ) -> AsyncThrowingStream<DeliverableRunEvent, Error> {
        stream { service, emit in
            try await service.run(
                .template(templateID: templateID, userNotes: userNotes), transcriptionID: transcriptionID,
                model: model, override: override, emit: emit)
        }
    }

    /// Answers a question about a transcript with `[mm:ss]` citations. Not stored as a deliverable.
    public nonisolated func ask(
        question: String,
        transcriptionID: UUID,
        model: any LanguageModel,
        override: PrivacyOverride? = nil
    ) -> AsyncThrowingStream<DeliverableRunEvent, Error> {
        stream { service, emit in
            try await service.run(
                .ask(question: question), transcriptionID: transcriptionID, model: model, override: override,
                emit: emit)
        }
    }

    private nonisolated func stream(
        _ body:
            @escaping @Sendable (DeliverableService, @escaping @Sendable (DeliverableRunEvent) -> Void)
            async throws -> Void
    ) -> AsyncThrowingStream<DeliverableRunEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await body(self) { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private enum RunKind: Sendable {
        case template(templateID: UUID, userNotes: String?)
        case ask(question: String)
    }

    /// Mutable bookkeeping for the ledger row.
    private struct RunMetrics: Sendable {
        var calls = 0
        var promptTokens: Int?
        var completionTokens: Int?
        var model: String?

        mutating func add(_ usage: GenerationUsage) {
            if let tokens = usage.promptTokens { promptTokens = (promptTokens ?? 0) + tokens }
            if let tokens = usage.completionTokens { completionTokens = (completionTokens ?? 0) + tokens }
            model = usage.model ?? model
        }
    }

    private func run(
        _ kind: RunKind,
        transcriptionID: UUID,
        model: any LanguageModel,
        override token: PrivacyOverride?,
        emit: @escaping @Sendable (DeliverableRunEvent) -> Void
    ) async throws {
        let runID = UUID()
        let started = now()
        let feature: LanguageModelRun.Feature
        if case .ask = kind { feature = .ask } else { feature = .deliverable }

        // 1. Read everything as stored now.
        guard let transcription = try await transcripts.fetch(id: transcriptionID) else {
            throw DeliverableError.transcriptNotFound
        }
        var template: PromptTemplate?
        var version: PromptVersion?
        let task: GenerationTask
        switch kind {
        case .template(let templateID, let userNotes):
            guard let found = try await deliverables.fetchTemplate(id: templateID),
                let active = try await deliverables.fetchVersion(id: found.activeVersionID)
            else { throw DeliverableError.templateNotFound }
            template = found
            version = active
            task = GenerationTask(kind: .template(content: active.content), userNotes: userNotes)
        case .ask(let question):
            task = GenerationTask(kind: .ask(question: question))
        }
        let effective = try await EffectivePrivacyClass.of(transcription, in: deliverables)
        let route = makeRoute(
            transcription, baseClass: effective, outputClass: template?.outputPrivacyClass, model: model)
        var metrics = RunMetrics()
        let context = LedgerContext(
            runID: runID, started: started, feature: feature, transcriptionID: transcriptionID,
            promptVersionID: version?.id, route: route)

        // 2. Route before anything is sent.
        var overrideUsed = false
        if !isAllowed(route, model: model, override: false) {
            overrideUsed = consume(token, for: route)
            guard overrideUsed, isAllowed(route, model: model, override: true) else {
                let request = issueRequest(for: route)
                privacyLogger.notice(
                    "privacy_routing_refused run=\(runID, privacy: .public) transcription=\(transcriptionID, privacy: .public) engine=\(route.engineID, privacy: .public) locality=\(route.locality.rawValue, privacy: .public) class=\(route.privacyClass.rawValue, privacy: .public)"
                )
                await writeLedger(
                    context, metrics, .refused, error: DeliverableError.privacyOverrideRequired(request).kindName,
                    overrideUsed: false)
                throw DeliverableError.privacyOverrideRequired(request)
            }
            privacyLogger.notice(
                "privacy_override_used run=\(runID, privacy: .public) transcription=\(transcriptionID, privacy: .public) engine=\(route.engineID, privacy: .public) locality=\(route.locality.rawValue, privacy: .public) host=\(route.host ?? "-", privacy: .private)"
            )
        }

        let source = TranscriptPromptFormatter.timestampedText(for: transcription)
        do {
            guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw DeliverableError.emptyTranscript
            }
            if case .unavailable(let reason) = await model.availability() {
                throw DeliverableError.modelUnavailable(reason)
            }
            emit(.routed(route, privacyOverrideUsed: overrideUsed))
            logger.info(
                "run_started run=\(runID, privacy: .public) feature=\(feature.rawValue, privacy: .public) transcription=\(transcriptionID, privacy: .public) engine=\(route.engineID, privacy: .public) locality=\(route.locality.rawValue, privacy: .public) class=\(route.privacyClass.rawValue, privacy: .public) chars=\(source.count, privacy: .public)"
            )

            let text = try await generateText(
                task: task, source: source, route: route, model: model, overrideUsed: overrideUsed,
                metrics: &metrics, emit: emit)

            switch kind {
            case .template(_, let userNotes):
                let deliverable = Deliverable(
                    id: UUID(), transcriptionID: transcriptionID, promptID: template?.id,
                    promptVersionID: version?.id, title: template?.name ?? "Document", engineID: route.engineID,
                    provider: route.providerName, model: metrics.model, locality: route.locality, text: text,
                    privacyClass: route.privacyClass,
                    userNotes: userNotes.flatMap {
                        $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0
                    },
                    createdAt: now())
                try await deliverables.insertDeliverable(deliverable)
                await writeLedger(
                    context, metrics, .succeeded, input: source.count, output: text.count,
                    deliverableID: deliverable.id, overrideUsed: overrideUsed)
                emit(.completed(deliverable))
            case .ask:
                await writeLedger(
                    context, metrics, .succeeded, input: source.count, output: text.count, overrideUsed: overrideUsed)
                let citations = TranscriptCitationParser.citations(in: text, transcription: transcription)
                emit(.answered(AskAnswer(text: text, citations: citations, route: route)))
            }
            logger.info(
                "run_finished run=\(runID, privacy: .public) status=succeeded calls=\(metrics.calls, privacy: .public)")
        } catch {
            let errorName = Self.kindName(of: error)
            let status: LanguageModelRun.Status
            if error is CancellationError || Task.isCancelled {
                status = .cancelled
            } else if case DeliverableError.privacyOverrideRequired = error {
                status = .refused
            } else {
                status = .failed
            }
            await writeLedger(
                context, metrics, status, error: status == .cancelled ? nil : errorName, input: source.count,
                overrideUsed: overrideUsed)
            logger.notice(
                "run_finished run=\(runID, privacy: .public) status=\(status.rawValue, privacy: .public) error_type=\(errorName, privacy: .public) calls=\(metrics.calls, privacy: .public)"
            )
            throw error
        }
    }

    /// Plans and runs the model calls, re-planning with a smaller budget when a model says the input was too long.
    private func generateText(
        task: GenerationTask,
        source: String,
        route: ModelRoute,
        model: any LanguageModel,
        overrideUsed: Bool,
        metrics: inout RunMetrics,
        emit: @escaping @Sendable (DeliverableRunEvent) -> Void
    ) async throws -> String {
        var contextTokens =
            await model.contextWindowTokens() ?? GenerationBudget.defaultContextTokens(for: route.locality)
        for attempt in 0..<3 {
            let generator = MapReduceGenerator(
                task: task, privacyClass: route.privacyClass, budget: GenerationBudget(contextTokens: contextTokens))
            var callMetrics = RunMetrics()
            do {
                let text = try await generator.run(
                    source: source,
                    call: { request, phase in
                        try await self.recheckRoute(route, model: model, overrideUsed: overrideUsed)
                        return try await Self.send(
                            request, to: model, streamTo: phase.isFinal ? emit : nil, metrics: &callMetrics)
                    },
                    step: { step in
                        switch step {
                        case .reading(let part, let total): emit(.step(.reading(part: part, of: total)))
                        case .combining(let level): emit(.step(.combining(level: level)))
                        case .writing: emit(.step(.writing))
                        }
                    })
                metrics.calls += callMetrics.calls
                metrics.promptTokens = Self.sum(metrics.promptTokens, callMetrics.promptTokens)
                metrics.completionTokens = Self.sum(metrics.completionTokens, callMetrics.completionTokens)
                metrics.model = callMetrics.model ?? metrics.model
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { throw DeliverableError.emptyResult }
                return trimmed
            } catch LanguageModelError.contextTooLong where attempt < 2 {
                // The estimate was too generous for this model: plan again with half the window. Nothing is cut.
                metrics.calls += callMetrics.calls
                contextTokens /= 2
                logger.notice("run_replanned reason=context_too_long context_tokens=\(contextTokens, privacy: .public)")
            } catch LanguageModelError.contextTooLong {
                throw DeliverableError.transcriptTooLong
            }
        }
        throw DeliverableError.transcriptTooLong
    }

    /// Before every model call: the effective class as stored now (a deliverable made meanwhile counts), the policy as
    /// configured now, the same override.
    private func recheckRoute(_ route: ModelRoute, model: any LanguageModel, overrideUsed: Bool) async throws {
        guard
            let current = try await EffectivePrivacyClass.current(
                transcriptionID: route.transcriptionID, transcripts: transcripts, deliverables: deliverables)
        else {
            throw DeliverableError.transcriptNotFound
        }
        var now = route
        now.privacyClass = current.stricter(route.privacyClass)
        // An override covers the route it was confirmed for; a class raised since then needs a new confirmation.
        let covered = overrideUsed && now.privacyClass == route.privacyClass
        guard isAllowed(now, model: model, override: covered) else {
            privacyLogger.notice(
                "privacy_routing_refused_mid_run transcription=\(route.transcriptionID, privacy: .public) engine=\(route.engineID, privacy: .public) class=\(now.privacyClass.rawValue, privacy: .public)"
            )
            throw DeliverableError.privacyOverrideRequired(issueRequest(for: now))
        }
    }

    /// Sends one request and collects its text; only a completed stream (`.finished`) counts.
    private static func send(
        _ request: GenerationRequest,
        to model: any LanguageModel,
        streamTo emit: (@Sendable (DeliverableRunEvent) -> Void)?,
        metrics: inout RunMetrics
    ) async throws -> String {
        metrics.calls += 1
        var text = ""
        var finished = false
        for try await event in model.generate(request) {
            try Task.checkCancellation()
            switch event {
            case .text(let delta):
                text += delta
                emit?(.text(delta))
            case .usage(let usage):
                metrics.add(usage)
            case .finished:
                finished = true
            }
        }
        try Task.checkCancellation()
        guard finished else { throw LanguageModelError.streamingError("the response ended before it finished") }
        return text
    }

    /// What every ledger row of one run shares.
    private struct LedgerContext: Sendable {
        var runID: UUID
        var started: Date
        var feature: LanguageModelRun.Feature
        var transcriptionID: UUID
        var promptVersionID: UUID?
        var route: ModelRoute
    }

    private func writeLedger(
        _ context: LedgerContext,
        _ metrics: RunMetrics,
        _ status: LanguageModelRun.Status,
        error: String? = nil,
        input: Int = 0,
        output: Int? = nil,
        deliverableID: UUID? = nil,
        overrideUsed: Bool
    ) async {
        let route = context.route
        let entry = LanguageModelRun(
            id: context.runID, feature: context.feature, status: status, transcriptionID: context.transcriptionID,
            deliverableID: deliverableID, promptVersionID: context.promptVersionID, engineID: route.engineID,
            provider: route.providerName, model: metrics.model, locality: route.locality,
            privacyClass: route.privacyClass, privacyOverride: overrideUsed, errorType: error,
            promptTokens: metrics.promptTokens, completionTokens: metrics.completionTokens,
            latencyMs: Int((now().timeIntervalSince(context.started) * 1000).rounded()), inputCharacters: input,
            outputCharacters: output, callCount: metrics.calls)
        await record(entry)
    }

    private func record(_ run: LanguageModelRun) async {
        // Outside the run's cancellation: GRDB refuses writes from a cancelled task, and a cancelled run still
        // gets its ledger row.
        let store = deliverables
        let logger = self.logger
        await Task {
            do {
                try await store.recordRun(run)
            } catch {
                logger.error(
                    "run_ledger_write_failed run=\(run.id, privacy: .public) error_type=\(error.logTypeName, privacy: .public)"
                )
            }
        }.value
    }

    // MARK: - Edits (plan 022 Step 4: Edit by voice)

    /// The store's versions (`GRDBDeliverableStore` keeps them); nil means edits cannot be kept, so none run.
    private var versionStore: (any DeliverableVersionStoring)? { deliverables as? any DeliverableVersionStoring }

    /// What editing the document `deliverableID` with `model` needs. Routes on the transcript's effective class raised by
    /// the document's own. Sends nothing.
    public func routeEdit(deliverableID: UUID, model: any LanguageModel) async throws -> RouteDecision {
        let (transcription, document) = try await editSubject(deliverableID)
        let effective = try await EffectivePrivacyClass.of(transcription, in: deliverables)
        let route = makeRoute(transcription, baseClass: effective, outputClass: document.privacyClass, model: model)
        if isAllowed(route, model: model, override: false) { return .allowed(route) }
        return .needsOverride(issueRequest(for: route))
    }

    /// Rewrites a document from the person's instruction and stores the result as its **next version** (the text it
    /// had is kept as a version first; nothing is overwritten). Same routing, override and ledger rules as `generate`;
    /// the ledger row (`feature` `edit`) and the logs never hold the instruction or any text. One model call: a document
    /// that does not fit fails with `documentTooLongToEdit` before anything is sent.
    public nonisolated func edit(
        deliverableID: UUID,
        instruction: String,
        spoken: Bool,
        model: any LanguageModel,
        override: PrivacyOverride? = nil
    ) -> AsyncThrowingStream<DeliverableRunEvent, Error> {
        stream { service, emit in
            try await service.runEdit(
                deliverableID: deliverableID, instruction: instruction, spoken: spoken, model: model,
                override: override, emit: emit)
        }
    }

    private func editSubject(_ deliverableID: UUID) async throws -> (Transcription, Deliverable) {
        guard let document = try await deliverables.fetchDeliverable(id: deliverableID) else {
            throw DeliverableError.documentNotFound
        }
        guard let transcription = try await transcripts.fetch(id: document.transcriptionID) else {
            throw DeliverableError.transcriptNotFound
        }
        return (transcription, document)
    }

    private func runEdit(
        deliverableID: UUID,
        instruction rawInstruction: String,
        spoken: Bool,
        model: any LanguageModel,
        override token: PrivacyOverride?,
        emit: @escaping @Sendable (DeliverableRunEvent) -> Void
    ) async throws {
        let runID = UUID()
        let started = now()
        guard let versionStore else { throw DeliverableError.versionsUnavailable }
        let instruction = rawInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instruction.isEmpty else { throw DeliverableError.emptyInstruction }

        // 1. Read everything as stored now.
        let (transcription, document) = try await editSubject(deliverableID)
        let effective = try await EffectivePrivacyClass.of(transcription, in: deliverables)
        let route = makeRoute(transcription, baseClass: effective, outputClass: document.privacyClass, model: model)
        var metrics = RunMetrics()
        let context = LedgerContext(
            runID: runID, started: started, feature: .edit, transcriptionID: transcription.id, promptVersionID: nil,
            route: route)

        // 2. Route before anything is sent.
        var overrideUsed = false
        if !isAllowed(route, model: model, override: false) {
            overrideUsed = consume(token, for: route)
            guard overrideUsed, isAllowed(route, model: model, override: true) else {
                let request = issueRequest(for: route)
                privacyLogger.notice(
                    "privacy_routing_refused run=\(runID, privacy: .public) transcription=\(transcription.id, privacy: .public) engine=\(route.engineID, privacy: .public) locality=\(route.locality.rawValue, privacy: .public) class=\(route.privacyClass.rawValue, privacy: .public)"
                )
                await writeLedger(
                    context, metrics, .refused, error: DeliverableError.privacyOverrideRequired(request).kindName,
                    deliverableID: deliverableID, overrideUsed: false)
                throw DeliverableError.privacyOverrideRequired(request)
            }
            privacyLogger.notice(
                "privacy_override_used run=\(runID, privacy: .public) transcription=\(transcription.id, privacy: .public) engine=\(route.engineID, privacy: .public) locality=\(route.locality.rawValue, privacy: .public) host=\(route.host ?? "-", privacy: .private)"
            )
        }

        let source = document.text
        do {
            guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw DeliverableError.emptyDocument
            }
            if case .unavailable(let reason) = await model.availability() {
                throw DeliverableError.modelUnavailable(reason)
            }
            // One call must carry the whole document and have room to write it back: never cut, never map-reduce.
            let contextTokens =
                await model.contextWindowTokens() ?? GenerationBudget.defaultContextTokens(for: route.locality)
            let budget = GenerationBudget(contextTokens: contextTokens)
            let empty = DeliverablePromptAssembler.editRequest(
                instruction: instruction, document: "", privacyClass: route.privacyClass, maxOutputTokens: nil)
            let overhead = (empty.system?.count ?? 0) + empty.prompt.count
            guard source.count <= budget.sourceCharacters(overheadCharacters: overhead),
                source.count <= budget.maxOutputTokens * GenerationBudget.charactersPerToken
            else { throw DeliverableError.documentTooLongToEdit }

            emit(.routed(route, privacyOverrideUsed: overrideUsed))
            logger.info(
                "run_started run=\(runID, privacy: .public) feature=edit deliverable=\(deliverableID, privacy: .public) engine=\(route.engineID, privacy: .public) locality=\(route.locality.rawValue, privacy: .public) class=\(route.privacyClass.rawValue, privacy: .public) chars=\(source.count, privacy: .public)"
            )
            emit(.step(.writing))
            try await recheckRoute(route, model: model, overrideUsed: overrideUsed)
            let request = DeliverablePromptAssembler.editRequest(
                instruction: instruction, document: source, privacyClass: route.privacyClass,
                maxOutputTokens: budget.maxOutputTokens)
            let written: String
            do {
                written = try await Self.send(request, to: model, streamTo: emit, metrics: &metrics)
            } catch LanguageModelError.contextTooLong {
                throw DeliverableError.documentTooLongToEdit
            }
            let text = written.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw DeliverableError.emptyResult }
            guard
                let appended = try await versionStore.appendDeliverableVersion(
                    DeliverableVersionDraft(
                        text: text, origin: spoken ? .spokenEdit : .typedEdit, instruction: instruction,
                        engineID: route.engineID, provider: route.providerName, model: metrics.model,
                        locality: route.locality, privacyClass: route.privacyClass, createdAt: now()),
                    deliverableID: deliverableID)
            else { throw DeliverableError.documentNotFound }
            await writeLedger(
                context, metrics, .succeeded, input: source.count, output: text.count, deliverableID: deliverableID,
                overrideUsed: overrideUsed)
            emit(.completed(appended.deliverable))
            logger.info(
                "run_finished run=\(runID, privacy: .public) status=succeeded version=\(appended.versions.count, privacy: .public)"
            )
        } catch {
            let errorName = Self.kindName(of: error)
            let status: LanguageModelRun.Status
            if error is CancellationError || Task.isCancelled {
                status = .cancelled
            } else if case DeliverableError.privacyOverrideRequired = error {
                status = .refused
            } else {
                status = .failed
            }
            await writeLedger(
                context, metrics, status, error: status == .cancelled ? nil : errorName, input: source.count,
                deliverableID: deliverableID, overrideUsed: overrideUsed)
            logger.notice(
                "run_finished run=\(runID, privacy: .public) status=\(status.rawValue, privacy: .public) error_type=\(errorName, privacy: .public)"
            )
            throw error
        }
    }

    private static func sum(_ lhs: Int?, _ rhs: Int?) -> Int? {
        guard lhs != nil || rhs != nil else { return nil }
        return (lhs ?? 0) + (rhs ?? 0)
    }

    private static func kindName(of error: Error) -> String {
        if let error = error as? DeliverableError { return error.kindName }
        if let error = error as? LanguageModelError { return error.kindName }
        if error is CancellationError { return "cancelled" }
        return error.logTypeName
    }
}
