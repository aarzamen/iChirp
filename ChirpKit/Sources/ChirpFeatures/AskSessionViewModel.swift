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

    @ObservationIgnored private let service: DeliverableService

    public init(service: DeliverableService, transcriptionID: UUID) {
        self.service = service
        self.transcriptionID = transcriptionID
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
