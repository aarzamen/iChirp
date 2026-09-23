// Semantics from MacParakeet (GPL-3.0): Sources/MacParakeetCore/Services/LLM/LLMRunRecorder.swift @ bbae9e0e — a
// metadata-only run ledger row for every run, no content in logs. Fresh implementation for iChirp's decision models
// (plan 021): clinical items are refused outright, only a 3,000-character excerpt and content-free facts are sent.

import ChirpCore
import ChirpText
import Foundation

/// **The only path from a transcript to a `DecisionModel`.** Every run:
/// 1. reads the transcript as stored now; an empty one fails;
/// 2. routes it: a **clinical item is refused outright** (no override for decision engines in v1), and anything the
///    routing policy refuses is refused the same way; both write a `refused` ledger row and send nothing;
/// 3. windows it (`DecisionInputWindow`): at most 3,000 characters plus content-free facts, nothing else;
/// 4. builds the recipe's questions, re-reads the class just before sending, makes one call, applies the gate;
/// 5. writes exactly one metadata-only `LanguageModelRun` (`feature = .decision`) whatever the outcome.
public actor DecisionService {
    private let transcripts: any TranscriptionStoring
    private let ledger: any DeliverableStoring
    private let routingPolicy: @Sendable () -> PrivacyRoutingPolicy
    private let settings: any JevSettingsStoring
    private let factory: any DecisionModelFactory
    private let now: @Sendable () -> Date
    private let logger = Log.logger("decisions")
    private let privacyLogger = Log.logger("privacy")

    /// - Parameters:
    ///   - ledger: the run-ledger writer `DeliverableService` uses (`recordRun`).
    ///   - routingPolicy: read at every run, like `DeliverableService`.
    public init(
        transcripts: any TranscriptionStoring,
        ledger: any DeliverableStoring,
        routingPolicy: @escaping @Sendable () -> PrivacyRoutingPolicy,
        settings: any JevSettingsStoring,
        factory: any DecisionModelFactory,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.transcripts = transcripts
        self.ledger = ledger
        self.routingPolicy = routingPolicy
        self.settings = settings
        self.factory = factory
        self.now = now
    }

    /// Runs `recipe` on the transcript with Jev. Throws `DecisionError`, `LanguageModelError`, `DecisionRequestError`
    /// or `CancellationError`; a refusal is an outcome, not an error.
    public func run(recipe: DecisionRecipe, transcriptionID: UUID) async throws -> DecisionOutcome {
        let current = settings.load()
        guard current.isEnabled else { throw DecisionError.disabled }
        guard let transcription = try await transcripts.fetch(id: transcriptionID) else {
            throw DecisionError.transcriptNotFound
        }
        let runID = UUID()
        let started = now()
        let apiKey = try settings.apiKey()
        let engine = factory.makeJev(settings: current, apiKey: apiKey)
        var ledgerRow = LedgerContext(
            runID: runID, started: started, transcriptionID: transcriptionID, descriptor: engine.descriptor,
            model: current.model, privacyClass: transcription.privacyClass)

        // 2. Route before anything is built or sent.
        if let refusal = refusal(for: transcription.privacyClass, engine: engine) {
            privacyLogger.notice(
                "decision_refused run=\(runID, privacy: .public) transcription=\(transcriptionID, privacy: .public) engine=\(engine.descriptor.id, privacy: .public) class=\(transcription.privacyClass.rawValue, privacy: .public) reason=\(refusal == .blockedClinical ? "clinical" : "routing", privacy: .public)"
            )
            await write(
                ledgerRow, .refused, error: refusal == .blockedClinical ? "clinical_blocked" : "routing_refused")
            return refusal
        }

        var inputCharacters = 0
        do {
            // 3. Window.
            let paragraphs = DecisionInputWindow.paragraphs(of: transcription)
            let facts = DecisionInputWindow.facts(for: transcription, paragraphCount: paragraphs.count)
            let window: (text: String, indexes: [Int])
            switch recipe {
            case .recordingKind, .templateSuggestion:
                window = (DecisionInputWindow.excerpt(transcription.displayText), [])
            case .paragraphTags:
                window = DecisionInputWindow.paragraphExcerpt(paragraphs)
            }
            let text = window.text
            let paragraphIndexes = window.indexes
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw DecisionError.emptyTranscript
            }
            inputCharacters = text.count
            guard apiKey != nil else { throw DecisionError.missingKey }
            if case .unavailable(let reason) = await engine.availability() {
                throw LanguageModelError.unavailable(reason)
            }

            // 4. Questions, a last check of the class as stored now, one call.
            let request = DecisionRequest(
                state: DecisionState(text: text, facts: facts),
                questions: recipe.questions(paragraphIndexes: paragraphIndexes),
                privacyClass: transcription.privacyClass)
            try request.validate()
            if let latest = try await transcripts.fetch(id: transcriptionID),
                latest.privacyClass != ledgerRow.privacyClass
            {
                ledgerRow.privacyClass = latest.privacyClass.stricter(ledgerRow.privacyClass)
                if let refusal = refusal(for: ledgerRow.privacyClass, engine: engine) {
                    privacyLogger.notice(
                        "decision_refused_before_send run=\(runID, privacy: .public) class=\(ledgerRow.privacyClass.rawValue, privacy: .public)"
                    )
                    await write(ledgerRow, .refused, error: "clinical_blocked", input: 0)
                    return refusal
                }
            }
            logger.info(
                "decision_started run=\(runID, privacy: .public) recipe=\(recipe.rawValue, privacy: .public) transcription=\(transcriptionID, privacy: .public) class=\(ledgerRow.privacyClass.rawValue, privacy: .public) chars=\(inputCharacters, privacy: .public) questions=\(request.questions.count, privacy: .public)"
            )
            let result = try await engine.decide(request)

            let report = Self.report(
                recipe: recipe, transcriptionID: transcriptionID, result: result, questions: request.questions,
                paragraphIndexes: paragraphIndexes, privacyClass: ledgerRow.privacyClass)
            ledgerRow.model = result.model
            await write(
                ledgerRow, .succeeded, input: inputCharacters, calls: 1, latencyMs: result.latencyMs,
                tokens: (result.inputTokens, result.outputTokens))
            logger.info("decision_finished run=\(runID, privacy: .public) status=succeeded")
            return .decided(report)
        } catch {
            let status: LanguageModelRun.Status =
                (error is CancellationError || Task.isCancelled) ? .cancelled : .failed
            let errorName = Self.kindName(of: error)
            let sent = !(error is DecisionError || error is DecisionRequestError || Self.isLocalUnavailable(error))
            await write(
                ledgerRow, status, error: status == .cancelled ? nil : errorName, input: sent ? inputCharacters : 0,
                calls: sent ? 1 : 0)
            logger.notice(
                "decision_finished run=\(runID, privacy: .public) status=\(status.rawValue, privacy: .public) error_type=\(errorName, privacy: .public)"
            )
            throw error
        }
    }

    // MARK: - Routing

    private func refusal(for privacyClass: PrivacyClass, engine: any DecisionModel) -> DecisionOutcome? {
        // v1: a decision engine never receives a clinical item, whatever its locality, trust or an override says.
        if privacyClass == .clinical { return .blockedClinical }
        let allowed = routingPolicy().allows(
            engine.descriptor, for: privacyClass, host: engine.endpointHost?.lowercased(), userOverride: false)
        return allowed ? nil : .blockedByRouting
    }

    // MARK: - Report

    static func report(
        recipe: DecisionRecipe,
        transcriptionID: UUID,
        result: DecisionResult,
        questions: [DecisionQuestion],
        paragraphIndexes: [Int],
        privacyClass: PrivacyClass
    ) -> DecisionReport {
        var items: [DecisionItem] = []
        for (position, question) in questions.enumerated() {
            guard let answer = result.answers[question.id] else { continue }
            items.append(
                DecisionItem(
                    id: question.id,
                    paragraphIndex: recipe == .paragraphTags ? paragraphIndexes[position] : nil,
                    choice: answer.choice,
                    choiceTitle: recipe.optionTitle(answer.choice),
                    confidence: answer.confidence,
                    verdict: DecisionGate.verdict(for: answer.confidence),
                    options: answer.rankedOptions.map {
                        DecisionOption(id: $0.id, title: recipe.optionTitle($0.id), probability: $0.probability)
                    }))
        }
        return DecisionReport(
            recipe: recipe, transcriptionID: transcriptionID, model: result.model, latencyMs: result.latencyMs,
            privacyClass: privacyClass, items: items)
    }

    // MARK: - Ledger

    private struct LedgerContext: Sendable {
        var runID: UUID
        var started: Date
        var transcriptionID: UUID
        var descriptor: EngineDescriptor
        var model: String
        var privacyClass: PrivacyClass
    }

    private func write(
        _ context: LedgerContext,
        _ status: LanguageModelRun.Status,
        error: String? = nil,
        input: Int = 0,
        calls: Int = 0,
        latencyMs: Int? = nil,
        tokens: (Int?, Int?) = (nil, nil)
    ) async {
        let run = LanguageModelRun(
            id: context.runID, feature: .decision, status: status, transcriptionID: context.transcriptionID,
            engineID: context.descriptor.id, provider: context.descriptor.provider, model: context.model,
            locality: context.descriptor.locality, privacyClass: context.privacyClass, privacyOverride: false,
            errorType: error, promptTokens: tokens.0, completionTokens: tokens.1,
            latencyMs: latencyMs ?? Int((now().timeIntervalSince(context.started) * 1000).rounded()),
            inputCharacters: input, outputCharacters: nil, callCount: calls, createdAt: now())
        // Outside the run's cancellation: GRDB refuses writes from a cancelled task, and a cancelled run still gets
        // its ledger row (as in DeliverableService).
        let store = ledger
        let logger = self.logger
        await Task {
            do {
                try await store.recordRun(run)
            } catch {
                logger.error(
                    "decision_ledger_write_failed run=\(run.id, privacy: .public) error_type=\(error.logTypeName, privacy: .public)"
                )
            }
        }.value
    }

    private static func kindName(of error: Error) -> String {
        if let error = error as? DecisionError { return error.kindName }
        if let error = error as? LanguageModelError { return error.kindName }
        if let error = error as? DecisionRequestError { return error.kindName }
        if error is CancellationError { return "cancelled" }
        return error.logTypeName
    }

    /// Decided before any request: `unavailable` (offline `availability()`) and `contextTooLong` (the engine's size
    /// check). Nothing was sent.
    private static func isLocalUnavailable(_ error: Error) -> Bool {
        switch error as? LanguageModelError {
        case .unavailable?, .contextTooLong?: true
        default: false
        }
    }
}
