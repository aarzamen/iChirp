import ChirpCore
import Foundation
import Observation

/// One Transform or Ask run for a screen: routes first, asks for the clinical confirmation when the router wants
/// one, streams the result, and reports failures as sentences. Testable without the GUI.
@MainActor @Observable public final class DeliverableRunViewModel {
    public enum Request: Sendable, Equatable {
        case template(id: UUID, userNotes: String?)
        case ask(question: String)
        /// Plan 022: rewrite the document `deliverableID` from an instruction, stored as its next version.
        case edit(deliverableID: UUID, instruction: String, spoken: Bool)
    }

    public enum Phase: Equatable {
        case idle
        case checking
        /// Show `request.title` / `request.message` with Send and Cancel.
        case needsConfirmation(PrivacyOverrideRequest)
        case running(DeliverableRunStep?)
        case completed(Deliverable)
        case answered(AskAnswer)
        case failed(String)
    }

    public private(set) var phase: Phase = .idle
    /// The final text as it streams in (reset whenever the writing step starts).
    public private(set) var text = ""
    /// The route of the current run, for the locality chip ("On this iPhone", "Mac Studio", "Claude").
    public private(set) var route: ModelRoute?

    @ObservationIgnored private let service: DeliverableService
    @ObservationIgnored private let model: any LanguageModel
    @ObservationIgnored private let transcriptionID: UUID
    @ObservationIgnored private let request: Request
    @ObservationIgnored private var task: Task<Void, Never>?
    /// Plan 022: called after the person answered the clinical question (the run then finished, failed, asked again
    /// or, after Cancel, went back to `.idle`), so a chain waiting on this run (`CreateFlow`) can go on. Only the
    /// dialog answers; this hook never confirms anything itself.
    @ObservationIgnored public var onAnswered: (@MainActor () -> Void)?

    public init(service: DeliverableService, model: any LanguageModel, transcriptionID: UUID, request: Request) {
        self.service = service
        self.model = model
        self.transcriptionID = transcriptionID
        self.request = request
    }

    /// Asks the router; runs at once when allowed, otherwise waits in `.needsConfirmation`. Sends nothing before that.
    public func start() async {
        phase = .checking
        let templateID: UUID?
        if case .template(let id, _) = request { templateID = id } else { templateID = nil }
        do {
            let decision: RouteDecision
            if case .edit(let deliverableID, _, _) = request {
                decision = try await service.routeEdit(deliverableID: deliverableID, model: model)
            } else {
                decision = try await service.route(
                    transcriptionID: transcriptionID, templateID: templateID, model: model)
            }
            switch decision {
            case .allowed(let route):
                self.route = route
                await run(override: nil)
            case .needsOverride(let request):
                route = request.route
                phase = .needsConfirmation(request)
            }
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// The user tapped Send in the clinical confirmation: this run only.
    public func confirmOverride() async {
        guard case .needsConfirmation(let request) = phase else { return }
        do {
            let token = try await service.confirmOverride(request)
            await run(override: token)
        } catch {
            phase = .failed(error.localizedDescription)
        }
        onAnswered?()
    }

    /// The user declined: nothing was sent.
    public func declineOverride() {
        guard case .needsConfirmation = phase else { return }
        phase = .idle
        onAnswered?()
    }

    public func cancel() {
        task?.cancel()
    }

    private func run(override: PrivacyOverride?) async {
        phase = .running(nil)
        text = ""
        let stream: AsyncThrowingStream<DeliverableRunEvent, Error>
        switch request {
        case .template(let id, let notes):
            stream = service.generate(
                templateID: id, transcriptionID: transcriptionID, userNotes: notes, model: model, override: override)
        case .ask(let question):
            stream = service.ask(question: question, transcriptionID: transcriptionID, model: model, override: override)
        case .edit(let deliverableID, let instruction, let spoken):
            stream = service.edit(
                deliverableID: deliverableID, instruction: instruction, spoken: spoken, model: model,
                override: override)
        }
        let task = Task { await consume(stream) }
        self.task = task
        await task.value
        self.task = nil
    }

    private func consume(_ stream: AsyncThrowingStream<DeliverableRunEvent, Error>) async {
        do {
            for try await event in stream {
                switch event {
                case .routed(let route, _):
                    self.route = route
                case .step(let step):
                    if step == .writing { text = "" }
                    phase = .running(step)
                case .text(let delta):
                    text += delta
                case .completed(let deliverable):
                    text = deliverable.text
                    phase = .completed(deliverable)
                case .answered(let answer):
                    text = answer.text
                    phase = .answered(answer)
                }
            }
            if case .running = phase { phase = .failed("Cancelled. Nothing was saved.") }
        } catch DeliverableError.privacyOverrideRequired(let request) {
            // The class changed or the host stopped being trusted mid-run: ask again.
            phase = .needsConfirmation(request)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}
