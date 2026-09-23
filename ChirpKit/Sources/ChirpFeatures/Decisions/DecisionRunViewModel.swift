import ChirpCore
import Foundation
import Observation

/// One Jev decision on one transcript, for the result sheet: running (a real request, no simulated progress), the
/// decision with its confidence and verdict, a refusal (nothing sent), or an error with Retry.
@MainActor @Observable public final class DecisionRunViewModel: Identifiable {
    public enum Phase: Equatable {
        case idle
        case running
        case decided(DecisionReport)
        /// The item is clinical (or the router refused): nothing was sent.
        case blocked(String)
        case failed(String)
    }

    public let id = UUID()
    public let recipe: DecisionRecipe
    public let transcriptionID: UUID
    public private(set) var phase: Phase = .idle
    /// The last failure came from Jev's answer (or the network after the request left): the excerpt may have reached
    /// TypeSafe, and the sheet says so. False for refusals and failures before sending (no key, offline check).
    public private(set) var failedAfterSending = false

    /// The sentence shown for a clinical item, in the menu caption and the sheet.
    public nonisolated static let clinicalBlockedMessage = "Jev is a cloud service; clinical items stay on this iPhone."

    @ObservationIgnored private let service: DecisionService
    @ObservationIgnored private var task: Task<Void, Never>?

    public init(recipe: DecisionRecipe, transcriptionID: UUID, service: DecisionService) {
        self.recipe = recipe
        self.transcriptionID = transcriptionID
        self.service = service
    }

    /// Runs the decision once; a second call while running does nothing.
    public func start() async {
        guard phase != .running else { return }
        phase = .running
        failedAfterSending = false
        let service = self.service
        let recipe = self.recipe
        let id = transcriptionID
        let task = Task { @MainActor [weak self] in
            do {
                let outcome = try await service.run(recipe: recipe, transcriptionID: id)
                guard !Task.isCancelled else { return }
                switch outcome {
                case .decided(let report): self?.phase = .decided(report)
                case .blockedClinical: self?.phase = .blocked(Self.clinicalBlockedMessage)
                case .blockedByRouting:
                    self?.phase = .blocked("Privacy routing does not allow Jev for this item. Nothing was sent.")
                }
            } catch is CancellationError {
                self?.phase = .idle
            } catch {
                guard !Task.isCancelled else { return }
                self?.failedAfterSending = Self.failureCameAfterSending(error)
                self?.phase = .failed(error.localizedDescription)
            }
        }
        self.task = task
        await task.value
    }

    /// `DecisionService`'s own rule for the ledger's `sent`: a `LanguageModelError` from the engine, except the checks
    /// made before sending (`unavailable`, `contextTooLong`). Service, request and Keychain errors are before sending.
    public nonisolated static func failureCameAfterSending(_ error: Error) -> Bool {
        switch error as? LanguageModelError {
        case nil, .unavailable?, .contextTooLong?: false
        default: true
        }
    }

    /// Retry after an error: a fresh request.
    public func retry() async {
        phase = .idle
        await start()
    }

    /// The sheet closed: stop the request.
    public func cancel() {
        task?.cancel()
        task = nil
        if phase == .running { phase = .idle }
    }
}
