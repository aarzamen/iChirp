import ChirpCore
import Foundation
import Observation

// Plan 022 Step 2: one chain from anything in to anything out. Fresh implementation for iChirp; every stage is an
// existing service (dictation, text items, links, the file and document pipelines, DeliverableService, voices).

/// What the person has.
public enum CreateInputKind: String, Codable, Sendable, CaseIterable {
    case speak, text, link, file
}

/// The input of one chain.
public enum CreateInput: Sendable, Equatable {
    /// Dictation through the Dictating screen (the final pass is the text).
    case speak
    /// Typed or pasted text, saved as a text item.
    case text(String)
    /// A podcast, media or YouTube link (downloaded and transcribed, or YouTube captions).
    case link(String)
    /// An audio or video file (transcribed) or a document (read), picked in Files.
    case file(URL)

    public var kind: CreateInputKind {
        switch self {
        case .speak: .speak
        case .text: .text
        case .link: .link
        case .file: .file
        }
    }
}

/// What the person wants.
public enum CreateOutput: Sendable, Equatable {
    /// The item itself: the transcript, the document's or the typed text.
    case transcript
    /// The built-in Summary template.
    case summary
    /// Any template (Meeting notes, SOAP note, Polish, a user template…).
    case document(templateID: UUID)
    /// The text spoken with the chosen voice and saved as an `.m4a`; `summarizeFirst` speaks a summary instead.
    case voiceMessage(summarizeFirst: Bool)

    /// The template the operation stage runs, or nil when there is none.
    public var templateID: UUID? {
        switch self {
        case .transcript, .voiceMessage(summarizeFirst: false): nil
        case .summary, .voiceMessage(summarizeFirst: true): BuiltInTemplates.summary.id
        case .document(let id): id
        }
    }

    /// Whether a language model is needed.
    public var needsLanguageModel: Bool { templateID != nil }

    /// Whether a voice is needed.
    public var needsVoice: Bool {
        if case .voiceMessage = self { return true }
        return false
    }
}

/// One chain: an input, an output, and the class a new item starts with.
public struct CreateRequest: Sendable, Equatable {
    public var input: CreateInput
    public var output: CreateOutput
    /// The class the new item is given before any step could leave the phone (`clinical` when the person says it holds
    /// patient information). Raise only: an item never becomes less private here.
    public var privacyClass: PrivacyClass

    public init(input: CreateInput, output: CreateOutput, privacyClass: PrivacyClass = .personal) {
        self.input = input
        self.output = output
        self.privacyClass = privacyClass
    }
}

/// How a spoken input ended (the Dictating screen owns recording, the final pass, Retry and Discard).
public enum CreateSpeechOutcome: Sendable, Equatable {
    /// The dictation's row, completed from the final pass.
    case saved(UUID)
    /// Nothing usable: the row kept for Retry (nil when none was made) and the sentence the screen showed.
    case failed(UUID?, String)
    /// The person discarded the recording.
    case discarded
}

/// The existing services a chain uses. The app wires them to its composition root; tests pass fakes.
public struct CreateFlowDependencies {
    /// Starts a dictation and returns once it is saved, failed or discarded.
    public var recordSpeech: @MainActor () async -> CreateSpeechOutcome
    /// Saves a text item (`TextItemService`) and returns it.
    public var saveText: @MainActor (String, PrivacyClass) async throws -> Transcription
    /// Resolves a link and creates its row; download and transcription continue as a tracked job (YouTube captions
    /// finish at once). Throws a readable error when nothing was created.
    public var startLink: @MainActor (String) async throws -> UUID
    /// Imports a picked file (audio, video or document) and starts its tracked job. Returns the new row's id.
    public var startFile: @MainActor (URL) async throws -> UUID
    /// Returns the row as stored once its job has ended (at once when it has none); nil when it is gone.
    public var waitForItem: @MainActor (UUID) async -> Transcription?
    /// Re-runs a failed row's job (the Library's Retry).
    public var retryItem: @MainActor (UUID) async -> Void
    /// The only path to a language model.
    public var deliverables: DeliverableService
    /// A fresh voice-message maker for one chain.
    public var makeVoiceMessage: @MainActor () -> any VoiceMessageProducing

    public init(
        recordSpeech: @escaping @MainActor () async -> CreateSpeechOutcome,
        saveText: @escaping @MainActor (String, PrivacyClass) async throws -> Transcription,
        startLink: @escaping @MainActor (String) async throws -> UUID,
        startFile: @escaping @MainActor (URL) async throws -> UUID,
        waitForItem: @escaping @MainActor (UUID) async -> Transcription?,
        retryItem: @escaping @MainActor (UUID) async -> Void,
        deliverables: DeliverableService,
        makeVoiceMessage: @escaping @MainActor () -> any VoiceMessageProducing
    ) {
        self.recordSpeech = recordSpeech
        self.saveText = saveText
        self.startLink = startLink
        self.startFile = startFile
        self.waitForItem = waitForItem
        self.retryItem = retryItem
        self.deliverables = deliverables
        self.makeVoiceMessage = makeVoiceMessage
    }
}

/// Runs one chain: **input** (speak, type, link, file) → **transcribe** (audio and video through the existing jobs) →
/// **operation** (none, Summary or a template, through `DeliverableService`) → **output** (the item, the document, or
/// a voice message).
///
/// - Each stage waits on the real completion of the service it calls; progress is the service's own (the job
///   center's `progress[itemID]`, the run's streamed text, the voice message's chunks). Nothing is simulated.
/// - A failure stops the chain at that stage with a sentence; `retry()` starts again at that stage.
/// - **Privacy:** a new item gets the requested class before any later step; the operation routes through
///   `DeliverableService` on the item's effective class as stored at every call, and the voice message on the source's
///   class as stored before every chunk. A clinical step bound off the phone waits for the existing per-run question,
///   which only the dialog answers (`onAnswered` resumes the chain). Jev is never called here.
/// - Logs carry ids, kinds and stage names only, never text.
@MainActor @Observable public final class CreateFlow {
    public enum Stage: Int, CaseIterable, Sendable, Comparable {
        case input, transcribe, operation, output

        public static func < (lhs: Stage, rhs: Stage) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public enum StageStatus: Sendable, Equatable {
        case pending, running, done, skipped
        case failed(String)
    }

    public enum Phase: Sendable, Equatable {
        case idle
        case running(Stage)
        /// The stage waits for the person's answer to a clinical question (the dialog shows it).
        case waitingForAnswer(Stage)
        case finished
        case failed(Stage, String)
        /// The person stopped the chain (or discarded the recording). An item already made stays in the Library.
        case cancelled
    }

    public private(set) var request: CreateRequest?
    public private(set) var phase: Phase = .idle
    public private(set) var stages: [Stage: StageStatus] = [:]
    /// The Library item the chain made, once it exists.
    public private(set) var itemID: UUID?
    /// That item as stored after its transcription (or reading) ended.
    public private(set) var item: Transcription?
    /// The operation's run (its streamed text, its step and its clinical question).
    public private(set) var operationRun: DeliverableRunViewModel?
    /// The document the operation stored.
    public private(set) var deliverable: Deliverable?
    /// The voice message being made (its progress and its clinical question).
    public private(set) var voiceMessage: (any VoiceMessageProducing)?
    public private(set) var voiceMessageFile: VoiceMessageFile?

    /// Running or waiting for an answer.
    public var isActive: Bool {
        switch phase {
        case .running, .waitingForAnswer: true
        case .idle, .finished, .failed, .cancelled: false
        }
    }

    @ObservationIgnored private let dependencies: CreateFlowDependencies
    @ObservationIgnored private var makeModel: (@MainActor () throws -> any LanguageModel)?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var chainID = UUID()
    @ObservationIgnored private let logger = Log.logger("create")

    public init(dependencies: CreateFlowDependencies) {
        self.dependencies = dependencies
    }

    // MARK: - Person's actions

    /// Runs `request` until it finishes, fails, or waits for an answer. `makeModel` builds the chosen language model
    /// when the operation needs one (it may throw a readable error; nothing is sent then).
    public func start(
        _ request: CreateRequest,
        makeModel: @escaping @MainActor () throws -> any LanguageModel
    ) async {
        stopWork()
        generation += 1
        chainID = UUID()
        self.request = request
        self.makeModel = makeModel
        itemID = nil
        item = nil
        operationRun = nil
        deliverable = nil
        voiceMessage = nil
        voiceMessageFile = nil
        stages = [
            .input: .pending,
            .transcribe: request.input.kind == .text ? .skipped : .pending,
            .operation: request.output.templateID == nil ? .skipped : .pending,
            .output: .pending,
        ]
        logger.notice(
            "create_started chain=\(self.chainID, privacy: .public) input=\(request.input.kind.rawValue, privacy: .public) output=\(Self.logName(request.output), privacy: .public) class=\(request.privacyClass.rawValue, privacy: .public)"
        )
        await run(from: .input, retrying: false, generation: generation)
    }

    /// After a failure: starts again at the stage that failed. An item already made is reused, never made twice.
    public func retry() async {
        guard case .failed(let stage, _) = phase, request != nil else { return }
        generation += 1
        logger.notice(
            "create_retry chain=\(self.chainID, privacy: .public) stage=\(Self.logName(stage), privacy: .public)")
        await run(from: stage, retrying: true, generation: generation)
    }

    /// Stops the chain: a running model call or voice message stops and stores nothing. A transcription job already
    /// started keeps going; its item stays in the Library.
    public func cancel() {
        guard isActive else { return }
        generation += 1
        stopWork()
        for stage in Stage.allCases where stages[stage] == .running {
            stages[stage] = .pending
        }
        phase = .cancelled
        logger.notice("create_cancelled chain=\(self.chainID, privacy: .public)")
    }

    /// Back to nothing (a new chain can start).
    public func reset() {
        if isActive { cancel() }
        generation += 1
        request = nil
        phase = .idle
        stages = [:]
        itemID = nil
        item = nil
        operationRun = nil
        deliverable = nil
        voiceMessage = nil
        voiceMessageFile = nil
    }

    // MARK: - The chain

    private enum StepResult {
        case done
        /// Failed, cancelled or waiting for an answer: the phase says which.
        case stop
    }

    private func run(from first: Stage, retrying: Bool, generation: Int) async {
        for stage in Stage.allCases where stage >= first {
            guard generation == self.generation else { return }
            if stages[stage] == .skipped { continue }
            let result = await perform(stage, retrying: retrying && stage == first, generation: generation)
            guard generation == self.generation, case .done = result else { return }
        }
        guard generation == self.generation else { return }
        phase = .finished
        logger.notice(
            "create_finished chain=\(self.chainID, privacy: .public) item=\(self.itemID?.uuidString ?? "-", privacy: .public) deliverable=\(self.deliverable?.id.uuidString ?? "-", privacy: .public)"
        )
    }

    private func perform(_ stage: Stage, retrying: Bool, generation: Int) async -> StepResult {
        stages[stage] = .running
        phase = .running(stage)
        switch stage {
        case .input: return await runInput(generation: generation)
        case .transcribe: return await runTranscribe(retrying: retrying, generation: generation)
        case .operation: return await runOperation(generation: generation)
        case .output: return await runOutput(retrying: retrying, generation: generation)
        }
    }

    // MARK: Input

    private func runInput(generation: Int) async -> StepResult {
        guard let request else { return .stop }
        if itemID == nil {
            do {
                switch request.input {
                case .speak:
                    switch await dependencies.recordSpeech() {
                    case .saved(let id):
                        itemID = id
                    case .failed(let id, let message):
                        guard generation == self.generation else { return .stop }
                        guard let id else { return fail(.input, message) }
                        // The recording was kept: the item exists and its transcription is what failed.
                        itemID = id
                        stages[.input] = .done
                        await applyPrivacyClass(generation: generation)
                        return fail(.transcribe, message)
                    case .discarded:
                        guard generation == self.generation else { return .stop }
                        stages[.input] = .pending
                        phase = .cancelled
                        logger.notice("create_discarded chain=\(self.chainID, privacy: .public)")
                        return .stop
                    }
                case .text(let text):
                    let saved = try await dependencies.saveText(text, request.privacyClass)
                    itemID = saved.id
                    item = saved
                case .link(let link):
                    itemID = try await dependencies.startLink(link)
                case .file(let url):
                    itemID = try await dependencies.startFile(url)
                }
            } catch {
                guard generation == self.generation else { return .stop }
                return fail(.input, Self.message(for: error))
            }
        }
        guard generation == self.generation else { return .stop }
        logger.notice(
            "create_item chain=\(self.chainID, privacy: .public) item=\(self.itemID?.uuidString ?? "-", privacy: .public)"
        )
        guard await applyPrivacyClass(generation: generation) else { return .stop }
        stages[.input] = .done
        return .done
    }

    /// Raises the new item to the requested class before anything else runs on it. Only a stricter class than the
    /// default is applied (a text item is saved with its class already), so an item is never lowered here.
    @discardableResult
    private func applyPrivacyClass(generation: Int) async -> Bool {
        guard let request, let itemID, request.input.kind != .text,
            request.privacyClass.strictness > PrivacyClass.personal.strictness
        else { return true }
        do {
            try await dependencies.deliverables.setPrivacyClass(request.privacyClass, transcriptionID: itemID)
            return true
        } catch {
            guard generation == self.generation else { return false }
            _ = fail(.input, "Couldn’t mark the item \(request.privacyClass.rawValue), so Parakeet stopped here.")
            return false
        }
    }

    // MARK: Transcribe

    private func runTranscribe(retrying: Bool, generation: Int) async -> StepResult {
        guard let itemID else { return fail(.transcribe, "There is no item to transcribe.") }
        if retrying {
            await dependencies.retryItem(itemID)
            guard generation == self.generation else { return .stop }
        }
        let row = await dependencies.waitForItem(itemID)
        guard generation == self.generation else { return .stop }
        guard let row else { return fail(.transcribe, "This item no longer exists. It may have been deleted.") }
        item = row
        switch row.status {
        case .completed:
            guard !row.displayText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return fail(.transcribe, "There was no text to work with.")
            }
            stages[.transcribe] = .done
            return .done
        case .failed, .interrupted:
            let message = row.errorMessage?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return fail(.transcribe, message.isEmpty ? "Parakeet couldn’t transcribe this." : message)
        case .cancelled:
            return fail(.transcribe, "The transcription was cancelled. The item is in your Library.")
        case .processing:
            return fail(.transcribe, "The job stopped before it finished. The item is in your Library.")
        }
    }

    // MARK: Operation

    private func runOperation(generation: Int) async -> StepResult {
        guard let request, let itemID, let templateID = request.output.templateID else {
            return fail(.operation, "There is nothing to run.")
        }
        if item == nil {
            item = await dependencies.waitForItem(itemID)
            guard generation == self.generation else { return .stop }
        }
        let model: any LanguageModel
        do {
            guard let makeModel else { return fail(.operation, "No language model is chosen.") }
            model = try makeModel()
        } catch {
            return fail(.operation, Self.message(for: error))
        }
        let run = DeliverableRunViewModel(
            service: dependencies.deliverables, model: model, transcriptionID: itemID,
            request: .template(id: templateID, userNotes: nil))
        run.onAnswered = { [weak self, weak run] in
            guard let self, let run else { return }
            Task { await self.operationAnswered(run, generation: generation) }
        }
        operationRun = run
        await run.start()
        guard generation == self.generation else { return .stop }
        return settleOperation(run)
    }

    private func settleOperation(_ run: DeliverableRunViewModel) -> StepResult {
        switch run.phase {
        case .completed(let document):
            deliverable = document
            stages[.operation] = .done
            return .done
        case .needsConfirmation:
            stages[.operation] = .running
            phase = .waitingForAnswer(.operation)
            logger.notice("create_waiting chain=\(self.chainID, privacy: .public) stage=operation")
            return .stop
        case .failed(let message):
            return fail(.operation, message)
        case .idle:
            // The person answered Cancel: nothing was sent.
            return fail(.operation, "Not sent. Nothing left this iPhone.")
        case .checking, .running, .answered:
            return fail(.operation, "The run ended before it finished. Nothing was saved.")
        }
    }

    /// The dialog answered the operation's question: continue when the run then finished.
    private func operationAnswered(_ run: DeliverableRunViewModel, generation: Int) async {
        guard generation == self.generation, run === operationRun, phase == .waitingForAnswer(.operation) else {
            return
        }
        phase = .running(.operation)
        guard case .done = settleOperation(run) else { return }
        await self.run(from: .output, retrying: false, generation: generation)
    }

    // MARK: Output

    private func runOutput(retrying: Bool, generation: Int) async -> StepResult {
        guard let request else { return .stop }
        guard case .voiceMessage = request.output else {
            stages[.output] = .done
            return .done
        }
        if item == nil, let itemID {
            item = await dependencies.waitForItem(itemID)
            guard generation == self.generation else { return .stop }
        }
        guard let voiceRequest = voiceMessageRequest() else {
            return fail(.output, "There is no text to speak.")
        }
        if retrying, let producer = voiceMessage, case .failed = producer.phase {
            await producer.retry()
            guard generation == self.generation else { return .stop }
            return settleOutput(producer)
        }
        let producer = dependencies.makeVoiceMessage()
        producer.onAnswered = { [weak self, weak producer] in
            guard let self, let producer else { return }
            Task { await self.outputAnswered(producer, generation: generation) }
        }
        voiceMessage = producer
        await producer.start(voiceRequest)
        guard generation == self.generation else { return .stop }
        return settleOutput(producer)
    }

    /// The text to speak: the operation's document when there is one, otherwise the item's text.
    private func voiceMessageRequest() -> VoiceMessageRequest? {
        guard let request, let item else { return nil }
        let text: String
        let source: VoiceSource
        let privacyClass: PrivacyClass
        let title: String
        if let deliverable {
            text = deliverable.text
            source = .deliverable(id: deliverable.id)
            privacyClass = deliverable.privacyClass.stricter(item.privacyClass)
            title = "\(deliverable.title) – \(item.displayTitle)"
        } else {
            text = item.displayText
            source = item.isTextOnly ? .document(id: item.id) : .transcript(id: item.id)
            privacyClass = item.privacyClass
            title = item.displayTitle
        }
        let speakable = SpeakableText.prepare(text)
        guard !speakable.isEmpty else { return nil }
        return VoiceMessageRequest(
            text: speakable, privacyClass: privacyClass.stricter(request.privacyClass), source: source,
            itemID: item.id, title: title)
    }

    private func settleOutput(_ producer: any VoiceMessageProducing) -> StepResult {
        switch producer.phase {
        case .finished(let file):
            voiceMessageFile = file
            stages[.output] = .done
            return .done
        case .needsConfirmation:
            stages[.output] = .running
            phase = .waitingForAnswer(.output)
            logger.notice("create_waiting chain=\(self.chainID, privacy: .public) stage=output")
            return .stop
        case .failed(let message):
            return fail(.output, message)
        case .idle:
            // The person answered Cancel: nothing was sent.
            return fail(.output, "No voice message was made. Nothing left this iPhone.")
        case .preparing, .synthesizing, .assembling:
            return fail(.output, "The voice message stopped before it finished.")
        }
    }

    private func outputAnswered(_ producer: any VoiceMessageProducing, generation: Int) async {
        guard generation == self.generation, producer === voiceMessage, phase == .waitingForAnswer(.output) else {
            return
        }
        phase = .running(.output)
        guard case .done = settleOutput(producer) else { return }
        phase = .finished
        logger.notice(
            "create_finished chain=\(self.chainID, privacy: .public) item=\(self.itemID?.uuidString ?? "-", privacy: .public)"
        )
    }

    // MARK: - Helpers

    private func fail(_ stage: Stage, _ message: String) -> StepResult {
        stages[stage] = .failed(message)
        phase = .failed(stage, message)
        logger.notice(
            "create_failed chain=\(self.chainID, privacy: .public) stage=\(Self.logName(stage), privacy: .public)")
        return .stop
    }

    private func stopWork() {
        operationRun?.cancel()
        voiceMessage?.cancel()
    }

    static func message(for error: any Error) -> String {
        if let description = (error as? any LocalizedError)?.errorDescription, !description.isEmpty {
            return description
        }
        return error.localizedDescription
    }

    static func logName(_ stage: Stage) -> String {
        switch stage {
        case .input: "input"
        case .transcribe: "transcribe"
        case .operation: "operation"
        case .output: "output"
        }
    }

    static func logName(_ output: CreateOutput) -> String {
        switch output {
        case .transcript: "transcript"
        case .summary: "summary"
        case .document: "document"
        case .voiceMessage(let summarizeFirst): summarizeFirst ? "voice_message_summary" : "voice_message"
        }
    }
}
