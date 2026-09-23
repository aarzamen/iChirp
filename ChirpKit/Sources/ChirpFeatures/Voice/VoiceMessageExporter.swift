// Plan 022 Step 5. Semantics from `VoicePlayer` (plan 020, itself from Readback's SynthQueue): sentence chunks, routing
// before every chunk on the source's class as stored at that moment, a per-message clinical question, transient
// retries. Fresh here: chunks are synthesized in order into temporary files and joined by `VoiceMessageWriting` into
// one `media/<id>/voice-<n>.m4a`, with real progress (chunks done of the total).

import ChirpCore
import Foundation
import Observation

/// Saves text as a voice message: the chosen voice (Settings → Voices) speaks it chunk by chunk, and the chunks are
/// joined into one `.m4a` in the item's media folder, ready for the share sheet.
///
/// **Routing** is `VoicePlayer`'s: before the first chunk, every later chunk and every retry, `PrivacyRoutingPolicy`
/// decides with the source's class as stored at that moment (`currentPrivacyClass`, raised, never lowered). Clinical
/// text bound for a cloud voice or an untrusted Mac waits in `.needsConfirmation`; **only the dialog's button calls
/// `confirmPendingSynthesis(requestID:)`** (the app's `VoiceMessageConfirmationActions`; `AppTests` scans for it).
/// Declining sends nothing. A confirmation covers this voice message's engine, locality, host and class only.
/// Logs carry the source kind, engine id, class and counts, never text.
@MainActor @Observable public final class VoiceMessageExporter: VoiceMessageProducing {
    public private(set) var phase: VoiceMessagePhase = .idle
    /// "Mac companion" or "Grok voices" once the voice is resolved.
    public private(set) var voiceName: String?
    @ObservationIgnored public var onAnswered: (@MainActor () -> Void)?

    private struct ConfirmedRoute: Equatable {
        let engineID: String
        let locality: EngineLocality
        let host: String?
        let privacyClass: PrivacyClass
    }

    private enum RouteCheck {
        case allowed, needsConfirmation, refused, stale
    }

    @ObservationIgnored private let selection: @MainActor () throws -> VoiceSelection
    @ObservationIgnored private let routingPolicy: @Sendable () -> PrivacyRoutingPolicy
    @ObservationIgnored private let currentPrivacyClass: @MainActor (VoiceSource) async -> PrivacyClass?
    @ObservationIgnored private let writer: any VoiceMessageWriting
    @ObservationIgnored private let paths: AppPaths
    @ObservationIgnored private let temporaryRoot: URL
    @ObservationIgnored private let retryDelays: [Duration]
    @ObservationIgnored private let logger = Log.logger("voice-message")

    @ObservationIgnored private var request: VoiceMessageRequest?
    @ObservationIgnored private var voice: VoiceSelection?
    @ObservationIgnored private var chunks: [SpeechTextChunk] = []
    @ObservationIgnored private var chunkFiles: [URL] = []
    @ObservationIgnored private var privacyClass: PrivacyClass = .clinical
    @ObservationIgnored private var confirmedRoute: ConfirmedRoute?
    @ObservationIgnored private var pendingRequest: VoiceConfirmationRequest?
    @ObservationIgnored private var workFolder: URL?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = 0

    /// Temporary chunk folders are `<temporaryRoot>/voice-message-<uuid>/`.
    public nonisolated static let temporaryPrefix = "voice-message-"

    /// - Parameters:
    ///   - selection: the engine and voice from Settings → Voices, read once per voice message.
    ///   - routingPolicy: read before every chunk (`VoicePlayer.routingPolicy(companion:)` in the app).
    ///   - currentPrivacyClass: the source's class as stored now (`VoiceSourcePrivacy.current`), before every chunk.
    ///   - retryDelays: waits between attempts of one chunk after a transient error.
    public init(
        selection: @escaping @MainActor () throws -> VoiceSelection,
        routingPolicy: @escaping @Sendable () -> PrivacyRoutingPolicy,
        currentPrivacyClass: @escaping @MainActor (VoiceSource) async -> PrivacyClass?,
        writer: any VoiceMessageWriting,
        paths: AppPaths,
        temporaryRoot: URL = FileManager.default.temporaryDirectory,
        retryDelays: [Duration] = [.milliseconds(500), .seconds(2)]
    ) {
        self.selection = selection
        self.routingPolicy = routingPolicy
        self.currentPrivacyClass = currentPrivacyClass
        self.writer = writer
        self.paths = paths
        self.temporaryRoot = temporaryRoot
        self.retryDelays = retryDelays
    }

    // MARK: - VoiceMessageProducing

    public func start(_ request: VoiceMessageRequest) async {
        cancel()
        self.request = request
        phase = .preparing
        let selected: VoiceSelection
        do {
            selected = try selection()
        } catch {
            phase = .failed(VoicePlayer.readableMessage(for: error, engineID: nil))
            return
        }
        voice = selected
        voiceName = selected.engine.descriptor.displayName
        chunks = SpeechChunker.chunk(request.text, hardCap: selected.engine.maxCharactersPerRequest)
        guard !chunks.isEmpty else {
            phase = .failed("There is no text to speak.")
            return
        }
        chunkFiles = []
        privacyClass = request.privacyClass
        confirmedRoute = nil
        logger.notice(
            "voice_message_started source=\(request.source.logName, privacy: .public) engine=\(selected.engine.descriptor.id, privacy: .public) class=\(request.privacyClass.rawValue, privacy: .public) chunks=\(self.chunks.count, privacy: .public)"
        )
        await runWork()
    }

    public func retry() async {
        guard case .failed = phase, let request else { return }
        guard voice != nil, !chunks.isEmpty else {
            await start(request)
            return
        }
        confirmedRoute = nil
        phase = .preparing
        await runWork()
    }

    public func cancel() {
        generation += 1
        task?.cancel()
        task = nil
        pendingRequest = nil
        removeWorkFolder()
        chunkFiles = []
        if phase != .idle, !isFinished { phase = .idle }
    }

    // MARK: - The dialog

    /// The dialog's button for the question that showed `requestID`: this voice message only. A stale answer confirms
    /// nothing.
    public func confirmPendingSynthesis(requestID: UUID) {
        guard case .needsConfirmation(let shown) = phase, shown.id == requestID, pendingRequest?.id == requestID
        else { return }
        pendingRequest = nil
        confirmedRoute = ConfirmedRoute(
            engineID: shown.engineID, locality: shown.locality, host: shown.host, privacyClass: privacyClass)
        logger.notice(
            "voice_message_override_confirmed engine=\(shown.engineID, privacy: .public) locality=\(shown.locality.rawValue, privacy: .public)"
        )
        phase = .preparing
        Task {
            await runWork()
            onAnswered?()
        }
    }

    /// The dialog's Cancel: nothing was sent.
    public func declinePendingSynthesis() {
        guard case .needsConfirmation = phase else { return }
        logger.notice("voice_message_confirmation_declined")
        pendingRequest = nil
        removeWorkFolder()
        chunkFiles = []
        phase = .idle
        onAnswered?()
    }

    // MARK: - Work

    private var isFinished: Bool {
        if case .finished = phase { return true }
        return false
    }

    /// Runs the remaining chunks and the assembly as one cancellable task and waits for it.
    private func runWork() async {
        generation += 1
        let generation = self.generation
        let task = Task { await self.work(generation: generation) }
        self.task = task
        await task.value
        if self.generation == generation { self.task = nil }
    }

    private func work(generation: Int) async {
        guard let request, let voice else { return }
        let engine = voice.engine
        if case .unavailable(let sentence) = await engine.availability() {
            guard generation == self.generation else { return }
            phase = .failed(sentence)
            return
        }
        while chunkFiles.count < chunks.count {
            guard generation == self.generation, !Task.isCancelled else { return }
            let index = chunkFiles.count
            switch await checkRoute(source: request.source, engine: engine, generation: generation) {
            case .allowed: break
            case .needsConfirmation:
                ask(engine: engine)
                return
            case .refused:
                logger.notice("voice_message_privacy_refused engine=\(engine.descriptor.id, privacy: .public)")
                phase = .failed(SpeechSynthesisError.privacyRefused.errorDescription ?? "")
                return
            case .stale:
                return
            }
            phase = .synthesizing(done: index, total: chunks.count)
            do {
                let audio = try await synthesize(index: index, voice: voice)
                guard generation == self.generation, !Task.isCancelled else { return }
                let folder = try ensureWorkFolder()
                let url = folder.appendingPathComponent("chunk-\(index).\(audio.format.fileExtension)")
                try audio.data.write(to: url, options: .atomic)
                chunkFiles.append(url)
            } catch is CancellationError {
                return
            } catch {
                guard generation == self.generation else { return }
                let kind = (error as? SpeechSynthesisError)?.kindName ?? error.logTypeName
                logger.error(
                    "voice_message_chunk_failed engine=\(engine.descriptor.id, privacy: .public) chunk=\(index, privacy: .public) error=\(kind, privacy: .public)"
                )
                phase = .failed(VoicePlayer.readableMessage(for: error, engineID: engine.descriptor.id))
                return
            }
        }
        phase = .synthesizing(done: chunks.count, total: chunks.count)
        await assemble(request: request, generation: generation)
    }

    private func synthesize(index: Int, voice: VoiceSelection) async throws -> SynthesizedAudio {
        var lastError: Error = SpeechSynthesisError.emptyAudio
        for attempt in 0...retryDelays.count {
            try Task.checkCancellation()
            if attempt > 0 {
                // Routing again before every retry: the class as stored now, the Mac's trust now.
                guard let request,
                    case .allowed = await checkRoute(
                        source: request.source, engine: voice.engine, generation: generation)
                else { throw lastError }
            }
            let chunk = chunks[index]
            let synthesis = SynthesisRequest(
                text: chunk.text, voiceID: voice.voiceID, style: voice.style, language: voice.language,
                previousText: index > 0 ? chunks[index - 1].text : nil,
                nextText: index < chunks.count - 1 ? chunks[index + 1].text : nil, privacyClass: privacyClass)
            do {
                let audio = try await voice.engine.synthesize(synthesis)
                guard !audio.data.isEmpty else { throw SpeechSynthesisError.emptyAudio }
                return audio
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
                guard attempt < retryDelays.count, VoicePlayer.isTransient(error) else { throw error }
                try await Task.sleep(for: retryDelays[attempt])
            }
        }
        throw lastError
    }

    private func assemble(request: VoiceMessageRequest, generation: Int) async {
        phase = .assembling
        let folder: URL
        do {
            folder = try ensureWorkFolder()
        } catch {
            phase = .failed("The voice message could not be saved: \(error.localizedDescription)")
            return
        }
        let temporary = folder.appendingPathComponent("message.m4a")
        let pauses = chunks.enumerated().map { index, chunk in
            chunk.endsParagraph && index < chunks.count - 1 ? VoicePlayer.paragraphPauseMs : 0
        }
        do {
            let durationMs = try await writer.writeVoiceMessage(
                chunks: chunkFiles, pausesAfterMs: pauses, to: temporary)
            guard generation == self.generation else { return }
            let file = try moveIntoMedia(temporary, itemID: request.itemID, durationMs: durationMs)
            removeWorkFolder()
            logger.notice(
                "voice_message_finished item=\(request.itemID, privacy: .public) chunks=\(self.chunks.count, privacy: .public) ms=\(durationMs, privacy: .public)"
            )
            phase = .finished(file)
        } catch {
            guard generation == self.generation else { return }
            logger.error("voice_message_write_failed error_type=\(error.logTypeName, privacy: .public)")
            phase = .failed(
                (error as? LocalizedError)?.errorDescription ?? "The voice message could not be saved.")
        }
    }

    /// Moves the finished file to `media/<itemID>/voice-<n>.m4a`, `n` one past the highest existing number.
    private func moveIntoMedia(_ temporary: URL, itemID: UUID, durationMs: Int) throws -> VoiceMessageFile {
        let directory = paths.mediaDirectory(for: itemID)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let number = Self.nextNumber(in: directory)
        let destination = directory.appendingPathComponent(Self.fileName(number: number), isDirectory: false)
        try FileManager.default.moveItem(at: temporary, to: destination)
        return VoiceMessageFile(
            url: destination,
            relativePath: paths.relativePath(for: destination)
                ?? "media/\(itemID.uuidString)/\(destination.lastPathComponent)",
            durationMs: durationMs, chunkCount: chunks.count)
    }

    /// `voice-<n>.m4a`.
    public nonisolated static func fileName(number: Int) -> String { "voice-\(number).m4a" }

    /// One past the highest `voice-<n>.m4a` in `directory` (1 when there is none).
    public nonisolated static func nextNumber(in directory: URL) -> Int {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let numbers = names.compactMap { name -> Int? in
            guard name.hasPrefix("voice-"), name.hasSuffix(".m4a") else { return nil }
            return Int(name.dropFirst("voice-".count).dropLast(".m4a".count))
        }
        return (numbers.max() ?? 0) + 1
    }

    // MARK: - Routing

    private func checkRoute(
        source: VoiceSource, engine: any SpeechSynthesizing, generation: Int
    ) async -> RouteCheck {
        let stored = await currentPrivacyClass(source)
        guard generation == self.generation else { return .stale }
        let raised = privacyClass.stricter(stored)
        if raised != privacyClass {
            logger.notice("voice_message_class_raised class=\(raised.rawValue, privacy: .public)")
            privacyClass = raised
        }
        let descriptor = engine.descriptor
        let host = engine.endpointHost?.lowercased()
        let covered =
            confirmedRoute
            == ConfirmedRoute(
                engineID: descriptor.id, locality: descriptor.locality, host: host, privacyClass: privacyClass)
        let policy = routingPolicy()
        if policy.allows(descriptor, for: privacyClass, host: host, userOverride: covered) { return .allowed }
        return policy.allows(descriptor, for: privacyClass, host: host, userOverride: true)
            ? .needsConfirmation : .refused
    }

    private func ask(engine: any SpeechSynthesizing) {
        let descriptor = engine.descriptor
        let question = VoiceConfirmationRequest(
            id: UUID(), engineID: descriptor.id, providerName: descriptor.displayName, locality: descriptor.locality,
            host: engine.endpointHost?.lowercased())
        pendingRequest = question
        phase = .needsConfirmation(question)
        logger.notice(
            "voice_message_confirmation_asked engine=\(descriptor.id, privacy: .public) locality=\(descriptor.locality.rawValue, privacy: .public)"
        )
    }

    // MARK: - Files

    private func ensureWorkFolder() throws -> URL {
        if let workFolder {
            try FileManager.default.createDirectory(at: workFolder, withIntermediateDirectories: true)
            return workFolder
        }
        let folder = temporaryRoot.appendingPathComponent(
            Self.temporaryPrefix + UUID().uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        workFolder = folder
        return folder
    }

    private func removeWorkFolder() {
        if let workFolder { try? FileManager.default.removeItem(at: workFolder) }
        workFolder = nil
    }

    /// Deletes `voice-message-*` folders a killed launch left in `root` (call once at launch). Returns how many went.
    @discardableResult
    public nonisolated static func sweepStaleWork(in root: URL = FileManager.default.temporaryDirectory) -> Int {
        let entries = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        var removed = 0
        for entry in entries where entry.lastPathComponent.hasPrefix(temporaryPrefix) {
            if (try? FileManager.default.removeItem(at: entry)) != nil { removed += 1 }
        }
        return removed
    }
}
