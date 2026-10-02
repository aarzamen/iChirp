// Fresh implementation for iChirp (M4 UI lane): the Ask tab's conversation. Each question is its own
// `DeliverableRunViewModel(.ask)` run, so routing, the clinical confirmation and the ledger apply to every question.

import ChirpCore
import Foundation
import Observation

/// Ask about one transcript: questions and their answers while the Transcript screen is open. Answers are not stored
/// as documents (the run ledger records each question's run, without content).
@MainActor @Observable public final class AskSessionViewModel {
    public struct Exchange: Identifiable {
        public let id = UUID()
        public let question: String
        /// The model picked for this question (the answer's real route is `run.route`).
        public let choice: LanguageModelChoice
        public let run: DeliverableRunViewModel
    }

    public let transcriptionID: UUID
    public private(set) var exchanges: [Exchange] = []
    /// The model the person picked on the Ask tab; nil until they pick one (the screen then shows the Settings default).
    /// Kept here, not in the tab's view, because the view is rebuilt on every tab switch (review R6b-1): a pick of
    /// "on this iPhone" must not fall back to a cloud default unasked.
    public var choice: LanguageModelChoice?
    /// The question typed but not sent yet, kept across tab switches for the same reason. Cleared when it is asked.
    public var draftQuestion = ""

    @ObservationIgnored private let service: DeliverableService

    public init(service: DeliverableService, transcriptionID: UUID) {
        self.service = service
        self.transcriptionID = transcriptionID
    }

    /// The picked model, or `fallback` (the Settings default) when nothing was picked yet.
    public func choice(default fallback: LanguageModelChoice) -> LanguageModelChoice {
        choice ?? fallback
    }

    /// A question is being routed, is waiting for the clinical confirmation, or is being answered.
    public var isBusy: Bool {
        guard let run = exchanges.last?.run else { return false }
        switch run.phase {
        case .checking, .running, .needsConfirmation: return true
        case .idle, .completed, .answered, .failed: return false
        }
    }

    /// Adds the question and runs it: routes first, and waits in `.needsConfirmation` when the router asks.
    public func ask(_ question: String, model: any LanguageModel, choice: LanguageModelChoice) async {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isBusy else { return }
        // The typed question is now asked; a suggestion asked while something is typed leaves the typing alone.
        if draftQuestion.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed { draftQuestion = "" }
        let run = DeliverableRunViewModel(
            service: service, model: model, transcriptionID: transcriptionID, request: .ask(question: trimmed))
        exchanges.append(Exchange(question: trimmed, choice: choice, run: run))
        await run.start()
    }

    /// Stops the question being answered. Nothing is stored for it.
    public func cancel() {
        exchanges.last?.run.cancel()
    }
}
