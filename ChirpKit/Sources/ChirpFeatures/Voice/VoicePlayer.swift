// Ported from Readback (owner's project): Sources/TTS/SynthQueue.swift @ 696cef6
// Changes: an `@Observable` `VoicePlayer` for SwiftUI; privacy routing (`PrivacyRoutingPolicy`) before the first and
// every later chunk and every retry, on the item's class as stored at that moment (an injected provider), with a
// per-utterance clinical confirmation for cloud or untrusted home-network voices, asked again mid-reading; one
// synthesis at a time and exactly one chunk ahead of the one playing (Readback: two in flight, two ahead), because the
// companion's single Mac GPU serves one request at a time; retries only for transient errors (connection, rate limit,
// 5xx); a failure lets queued audio finish, then offers Retry from the failed chunk; logs carry ids, counts and error
// kinds only.

import ChirpCore
import Foundation
import Observation

/// What is being read, for logs (never content) and the now-playing bar.
public enum VoiceSource: Sendable, Equatable {
    case transcript(id: UUID)
    /// An imported document (M5): PDF, Word, text.
    case document(id: UUID)
    /// A generated document (a Transform result).
    case deliverable(id: UUID)
    /// One Ask answer (the exchange's id) about the transcript `transcriptionID` (whose class it routes with).
    case askAnswer(id: UUID, transcriptionID: UUID)
    /// Plan 015's dictation "read back" command.
    case dictationReadBack(id: UUID?)
    /// Settings → Voices' Test voice (a fixed synthetic sentence).
    case voiceTest

    /// For the now-playing bar: "Transcript", "Document", "Answer".
    public var title: String {
        switch self {
        case .transcript: "Transcript"
        case .document: "Document"
        case .deliverable: "Document"
        case .askAnswer: "Answer"
        case .dictationReadBack: "Dictation"
        case .voiceTest: "Voice test"
        }
    }

    var logName: String {
        switch self {
        case .transcript: "transcript"
        case .document: "document"
        case .deliverable: "deliverable"
        case .askAnswer: "ask_answer"
        case .dictationReadBack: "dictation_read_back"
        case .voiceTest: "voice_test"
        }
    }
}

/// The engine and voice one utterance speaks with (resolved once per utterance from Settings → Voices).
public struct VoiceSelection: Sendable {
    public var engine: any SpeechSynthesizing
    public var voiceID: String
    public var style: String?
    public var language: String?

    public init(engine: any SpeechSynthesizing, voiceID: String, style: String? = nil, language: String? = nil) {
        self.engine = engine
        self.voiceID = voiceID
        self.style = style
        self.language = language
    }
}

/// The question the screen must ask before clinical text goes to a cloud voice (or a Mac the owner has not trusted).
/// Per utterance, never remembered.
public struct VoiceConfirmationRequest: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let engineID: String
    /// "Grok voices", "Mac companion".
    public let providerName: String
    public let locality: EngineLocality
    public let host: String?

    public init(id: UUID, engineID: String, providerName: String, locality: EngineLocality, host: String?) {
        self.id = id
        self.engineID = engineID
        self.providerName = providerName
        self.locality = locality
        self.host = host
    }

    /// "Read this clinical text aloud with Grok voices?"
    public var title: String {
        "Read this clinical text aloud with \(providerName)?"
    }

    public var message: String {
        switch locality {
        case .cloud:
            "The text will leave this iPhone and go to \(providerName) over the internet to be turned into speech. "
                + "This applies to this reading only."
        case .localNetwork:
            "The text will go to \(host ?? "a computer") on your network, which you have not marked as trusted. "
                + "This applies to this reading only."
        case .onDevice:
            "It stays on this iPhone."
        }
    }
}

/// Reads text aloud: chunks it on sentence boundaries, synthesizes one chunk ahead of the one playing, and plays
/// through `SpeechAudioPlaying` (the app's one audio session; recording pauses it).
///
/// **Routing:** before anything is sent, and again before every chunk and every retry of a chunk, `PrivacyRoutingPolicy`
/// decides, with the item's class **as stored at that moment** (`currentPrivacyClass`, never lower than the class the
/// reading started with). Clinical text bound for a cloud voice (or an untrusted Mac) waits in `.needsConfirmation`
/// until the user answers; declining sends nothing. When the class rises to clinical mid-reading, the reading stops
/// before the next chunk is sent and asks; Read aloud continues from the chunk that was playing. A confirmation covers
/// this utterance's route and class only (engine, locality, host).
@MainActor @Observable public final class VoicePlayer {
    public enum State: Equatable {
        case idle
        /// Checking the voice, or synthesizing the first chunk.
        case preparing
        /// Show `request.title` / `request.message` with Read aloud and Cancel.
        case needsConfirmation(VoiceConfirmationRequest)
        /// 1-based chunk number.
        case speaking(chunk: Int, of: Int)
        case paused(chunk: Int, of: Int)
        /// A sentence to show, with Retry.
        case failed(String)
    }

    /// Silence after a paragraph (Readback's default).
    public static let paragraphPauseMs = 350

    public private(set) var state: State = .idle
    /// What the current utterance reads; nil when idle.
    public private(set) var source: VoiceSource?
    /// "Mac companion" or "Grok voices" while an utterance is active.
    public private(set) var voiceName: String?

    /// Something is being read, prepared, confirmed, paused or has failed (the now-playing bar shows).
    public var isActive: Bool { state != .idle }

    private struct ConfirmedRoute: Equatable {
        let engineID: String
        let locality: EngineLocality
        let host: String?
        let privacyClass: PrivacyClass
    }

    private struct Utterance {
        let chunks: [SpeechTextChunk]
        /// The class this reading routes with: the class it started with, raised (never lowered) by the item's class
        /// as stored at each check.
        var privacyClass: PrivacyClass
        let source: VoiceSource
        let selection: VoiceSelection
        var confirmedRoute: ConfirmedRoute?
    }

    /// What routing says about the next request of this reading.
    private enum RouteCheck {
        case allowed
        /// Clinical text to a cloud voice or an untrusted Mac: ask first.
        case needsConfirmation
        /// Not even a confirmation may send it.
        case refused
        /// The reading was stopped or replaced while the class was read.
        case stale
    }

    @ObservationIgnored private let player: any SpeechAudioPlaying
    @ObservationIgnored private let selection: @MainActor () throws -> VoiceSelection
    @ObservationIgnored private let routingPolicy: @Sendable () -> PrivacyRoutingPolicy
    @ObservationIgnored private let currentPrivacyClass: @MainActor (VoiceSource) async -> PrivacyClass?
    @ObservationIgnored private let retryDelays: [Duration]
    @ObservationIgnored private let logger = Log.logger("voice")

    @ObservationIgnored private var utterance: Utterance?
    /// The last `speak` call, so Retry works even when the voice could not be resolved.
    @ObservationIgnored private var lastRequest: (text: String, privacyClass: PrivacyClass, source: VoiceSource)?
    @ObservationIgnored private var pendingRequest: VoiceConfirmationRequest?
    /// Bumped by every speak, retry and stop: late task results and player events of older ones are dropped.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var startIndex = 0
    @ObservationIgnored private var nextToSynth = 0
    @ObservationIgnored private var nextToEnqueue = 0
    @ObservationIgnored private var playingIndex = 0
    @ObservationIgnored private var results: [Int: SynthesizedAudio] = [:]
    @ObservationIgnored private var synthTask: Task<Void, Never>?
    @ObservationIgnored private var playerDrained = false
    @ObservationIgnored private var failedIndex: Int?
    @ObservationIgnored private var pendingFailure: String?

    /// - Parameters:
    ///   - selection: the engine and voice from Settings → Voices, read once per utterance.
    ///   - routingPolicy: read before every chunk, so un-trusting a Mac stops the next chunk of a running reading.
    ///   - currentPrivacyClass: the class of the item `source` names, **as stored now** (nil: nothing stored, such as
    ///     the Test voice sentence). Read before the first chunk, every later chunk and every retry, so marking a
    ///     transcript clinical while it is read stops the next chunk. The app answers with
    ///     `VoiceSourcePrivacy.current(for:…)` (the `EffectivePrivacyClass` rule).
    ///   - retryDelays: waits between attempts of one chunk after a transient error (Readback: 0.5 s, 2 s).
    public init(
        player: any SpeechAudioPlaying,
        selection: @escaping @MainActor () throws -> VoiceSelection,
        routingPolicy: @escaping @Sendable () -> PrivacyRoutingPolicy,
        currentPrivacyClass: @escaping @MainActor (VoiceSource) async -> PrivacyClass?,
        retryDelays: [Duration] = [.milliseconds(500), .seconds(2)]
    ) {
        self.player = player
        self.selection = selection
        self.routingPolicy = routingPolicy
        self.currentPrivacyClass = currentPrivacyClass
        self.retryDelays = retryDelays
    }

    /// True while `source` is the one being read (or prepared, confirmed, paused).
    public func isReading(_ source: VoiceSource) -> Bool {
        isActive && self.source == source
    }

    /// Whether `retry()` can do anything for the current failure (a reading with no text cannot be retried).
    public var canRetry: Bool {
        guard case .failed = state else { return false }
        return lastRequest != nil
    }

    // MARK: - Speaking

    /// Reads `text` aloud, replacing whatever was being read. Returns once reading started, or it is waiting for the
    /// clinical confirmation, or it failed. `privacyClass` is the class the screen knows; routing uses the stricter of
    /// it and the item's class as stored at each check. **Plan 015's dictation "read back" command calls this.**
    public func speak(text: String, privacyClass: PrivacyClass, source: VoiceSource) async {
        stop()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        self.source = source
        guard !trimmed.isEmpty else {
            state = .failed("There is no text to read.")
            return
        }
        lastRequest = (trimmed, privacyClass, source)
        state = .preparing
        let selection: VoiceSelection
        do {
            selection = try self.selection()
        } catch {
            fail(message(for: error, engineID: nil))
            return
        }
        voiceName = selection.engine.descriptor.displayName
        let chunks = SpeechChunker.chunk(trimmed, hardCap: selection.engine.maxCharactersPerRequest)
        guard !chunks.isEmpty else {
            fail("There is no text to read.")
            return
        }
        utterance = Utterance(
            chunks: chunks, privacyClass: privacyClass, source: source, selection: selection, confirmedRoute: nil)
        logger.notice(
            "voice_speak source=\(source.logName, privacy: .public) engine=\(selection.engine.descriptor.id, privacy: .public) class=\(privacyClass.rawValue, privacy: .public) chars=\(trimmed.count, privacy: .public) chunks=\(chunks.count, privacy: .public)"
        )
        await prepare(from: 0, generation: generation)
    }

    /// The user tapped Read aloud in the clinical confirmation that showed `requestID`: this utterance only. A stale
    /// answer (the question was replaced by another reading's) confirms nothing.
    public func confirmPendingSpeech(requestID: UUID) {
        guard case .needsConfirmation(let request) = state, request.id == requestID, pendingRequest?.id == requestID,
            var utterance
        else {
            return
        }
        pendingRequest = nil
        utterance.confirmedRoute = ConfirmedRoute(
            engineID: request.engineID, locality: request.locality, host: request.host,
            privacyClass: utterance.privacyClass)
        self.utterance = utterance
        logger.notice(
            "voice_privacy_override_confirmed engine=\(request.engineID, privacy: .public) locality=\(request.locality.rawValue, privacy: .public)"
        )
        start(from: startIndex)
    }

    /// The user tapped Cancel in the clinical confirmation: nothing was sent.
    public func declinePendingSpeech() {
        guard case .needsConfirmation = state else { return }
        logger.notice("voice_confirmation_declined")
        stop()
    }

    public func pause() {
        guard let utterance else { return }
        switch state {
        case .speaking(let chunk, let count):
            player.pause()
            state = .paused(chunk: chunk, of: count)
        case .preparing where pendingRequest == nil && synthTask != nil:
            player.pause()
            state = .paused(chunk: startIndex + 1, of: utterance.chunks.count)
        default:
            return
        }
    }

    public func resume() {
        guard case .paused(let chunk, let count) = state else { return }
        do {
            try player.resume()
        } catch {
            failNow(message(for: error, engineID: nil))
            return
        }
        // The player reports `.chunkStarted` when audio is queued; until the first chunk arrives we are preparing.
        state = nextToEnqueue > startIndex ? .speaking(chunk: chunk, of: count) : .preparing
    }

    /// Stops at once: pending synthesis is cancelled, audio stops, nothing more is sent.
    public func stop() {
        generation += 1
        synthTask?.cancel()
        synthTask = nil
        if utterance != nil { player.stop() }
        utterance = nil
        lastRequest = nil
        pendingRequest = nil
        results = [:]
        failedIndex = nil
        pendingFailure = nil
        playerDrained = false
        state = .idle
        source = nil
        voiceName = nil
    }

    /// After a failure: reads again from the chunk that failed (or from the start when the voice could not even be
    /// resolved). A clinical cloud reading asks again.
    public func retry() async {
        guard case .failed = state, let last = lastRequest else { return }
        guard var utterance, let failedIndex else {
            await speak(text: last.text, privacyClass: last.privacyClass, source: last.source)
            return
        }
        generation += 1
        utterance.confirmedRoute = nil
        self.utterance = utterance
        self.failedIndex = nil
        pendingFailure = nil
        state = .preparing
        await prepare(from: failedIndex, generation: generation)
    }

    // MARK: - Pipeline

    /// Availability (sends no text), then routing, then either start or ask.
    private func prepare(from index: Int, generation: Int) async {
        guard let utterance else { return }
        startIndex = index
        let engine = utterance.selection.engine
        let availability = await engine.availability()
        guard generation == self.generation, self.utterance != nil else { return }
        if case .unavailable(let sentence) = availability {
            failedIndex = index
            fail(sentence)
            return
        }
        switch await checkRoute(generation: generation) {
        case .allowed:
            start(from: index)
        case .needsConfirmation:
            ask(resumingAt: index)
        case .refused:
            failedIndex = index
            fail(SpeechSynthesisError.privacyRefused.errorDescription ?? "")
        case .stale:
            return
        }
    }

    /// Re-reads the item's class as stored now (raising this reading's class, never lowering it) and routes the next
    /// request with it. Main actor; nothing is sent here.
    private func checkRoute(generation: Int) async -> RouteCheck {
        guard let source = utterance?.source else { return .stale }
        let stored = await currentPrivacyClass(source)
        guard generation == self.generation, var utterance else { return .stale }
        let raised = utterance.privacyClass.stricter(stored)
        if raised != utterance.privacyClass {
            logger.notice(
                "voice_class_raised source=\(utterance.source.logName, privacy: .public) class=\(raised.rawValue, privacy: .public)"
            )
            utterance.privacyClass = raised
            self.utterance = utterance
        }
        let engine = utterance.selection.engine
        let descriptor = engine.descriptor
        let host = engine.endpointHost?.lowercased()
        let covered =
            utterance.confirmedRoute
            == ConfirmedRoute(
                engineID: descriptor.id, locality: descriptor.locality, host: host,
                privacyClass: utterance.privacyClass)
        let policy = routingPolicy()
        if policy.allows(descriptor, for: utterance.privacyClass, host: host, userOverride: covered) {
            return .allowed
        }
        return policy.allows(descriptor, for: utterance.privacyClass, host: host, userOverride: true)
            ? .needsConfirmation : .refused
    }

    /// Shows the clinical question; Read aloud starts (again) at `index`. Nothing more is sent until then.
    private func ask(resumingAt index: Int) {
        guard let utterance else { return }
        let engine = utterance.selection.engine
        let descriptor = engine.descriptor
        let request = VoiceConfirmationRequest(
            id: UUID(), engineID: descriptor.id, providerName: descriptor.displayName, locality: descriptor.locality,
            host: engine.endpointHost?.lowercased())
        startIndex = index
        pendingRequest = request
        state = .needsConfirmation(request)
        logger.notice(
            "voice_confirmation_asked engine=\(descriptor.id, privacy: .public) locality=\(descriptor.locality.rawValue, privacy: .public)"
        )
    }

    /// The class rose (or the Mac lost its trust) during a reading and the next chunk needs the question: stop the
    /// audio and pending work at once, then ask. Read aloud resumes at the chunk that was playing.
    private func askMidReading(beforeChunk index: Int) {
        generation += 1
        synthTask?.cancel()
        synthTask = nil
        player.stop()
        results = [:]
        playerDrained = false
        pendingFailure = nil
        failedIndex = nil
        let resumeAt = max(startIndex, min(playingIndex, index))
        logger.notice("voice_confirmation_mid_reading chunk=\(index, privacy: .public)")
        ask(resumingAt: resumeAt)
    }

    private func start(from index: Int) {
        do {
            try player.beginUtterance()
        } catch {
            failedIndex = index
            fail(message(for: error, engineID: nil))
            return
        }
        let generation = self.generation
        player.onEvent = { [weak self] event in
            self?.handle(event, generation: generation)
        }
        startIndex = index
        nextToSynth = index
        nextToEnqueue = index
        playingIndex = index
        results = [:]
        playerDrained = false
        failedIndex = nil
        pendingFailure = nil
        state = .preparing
        pump()
    }

    private func pump() {
        guard let utterance, failedIndex == nil else { return }
        let chunks = utterance.chunks
        // Hand finished audio to the player strictly in chunk order.
        // The player may report `.chunkStarted` from inside `enqueue`, so the counters move first.
        while let audio = results.removeValue(forKey: nextToEnqueue) {
            let index = nextToEnqueue
            nextToEnqueue += 1
            playerDrained = false
            let isFinal = index == chunks.count - 1
            let pause = chunks[index].endsParagraph && !isFinal ? Self.paragraphPauseMs : 0
            do {
                try player.enqueue(audio, index: index, pauseAfterMs: pause, isFinal: isFinal)
            } catch {
                logger.error("voice_enqueue_failed chunk=\(index, privacy: .public)")
                chunkFailed(at: index, message: "Parakeet could not play this audio.")
                return
            }
            guard self.utterance != nil, failedIndex == nil else { return }
        }
        // One synthesis at a time, never more than one chunk past the one playing.
        guard synthTask == nil, nextToSynth < chunks.count, nextToSynth <= playingIndex + 1 else { return }
        let index = nextToSynth
        nextToSynth += 1
        spawnSynthesis(for: index, utterance: utterance)
    }

    private func spawnSynthesis(for index: Int, utterance: Utterance) {
        let chunks = utterance.chunks
        let selection = utterance.selection
        let engine = selection.engine
        let delays = retryDelays
        let generation = self.generation
        synthTask = Task { [weak self] in
            var lastError: Error = SpeechSynthesisError.emptyAudio
            for attempt in 0...delays.count {
                if Task.isCancelled { return }
                // Routing before every call, retries included: the class as stored now, the Mac's trust now.
                guard let self, let privacyClass = await self.routedClass(forChunk: index, generation: generation)
                else { return }
                let request = SynthesisRequest(
                    text: chunks[index].text,
                    voiceID: selection.voiceID,
                    style: selection.style,
                    language: selection.language,
                    previousText: index > 0 ? chunks[index - 1].text : nil,
                    nextText: index < chunks.count - 1 ? chunks[index + 1].text : nil,
                    privacyClass: privacyClass
                )
                do {
                    let audio = try await engine.synthesize(request)
                    guard !Task.isCancelled else { return }
                    self.synthesized(audio, index: index, generation: generation)
                    return
                } catch is CancellationError {
                    return
                } catch {
                    lastError = error
                    guard attempt < delays.count, Self.isTransient(error) else { break }
                    try? await Task.sleep(for: delays[attempt])
                }
            }
            guard !Task.isCancelled else { return }
            self?.synthesisFailed(lastError, index: index, generation: generation)
        }
    }

    /// The class to send chunk `index` with, or nil when it must not be sent now: the reading changed, the question is
    /// asked (the class rose to clinical, or the Mac lost its trust), or routing refuses it.
    private func routedClass(forChunk index: Int, generation: Int) async -> PrivacyClass? {
        switch await checkRoute(generation: generation) {
        case .allowed:
            return utterance?.privacyClass
        case .needsConfirmation:
            askMidReading(beforeChunk: index)
            return nil
        case .refused:
            guard let utterance else { return nil }
            logger.notice("voice_privacy_refused engine=\(utterance.selection.engine.descriptor.id, privacy: .public)")
            synthTask = nil
            chunkFailed(at: index, message: SpeechSynthesisError.privacyRefused.errorDescription ?? "")
            return nil
        case .stale:
            return nil
        }
    }

    private func synthesized(_ audio: SynthesizedAudio, index: Int, generation: Int) {
        guard generation == self.generation else { return }
        synthTask = nil
        results[index] = audio
        pump()
    }

    private func synthesisFailed(_ error: Error, index: Int, generation: Int) {
        guard generation == self.generation, let utterance else { return }
        synthTask = nil
        let kind = (error as? SpeechSynthesisError)?.kindName ?? "other"
        logger.error(
            "voice_chunk_failed engine=\(utterance.selection.engine.descriptor.id, privacy: .public) chunk=\(index, privacy: .public) error=\(kind, privacy: .public)"
        )
        chunkFailed(at: index, message: message(for: error, engineID: utterance.selection.engine.descriptor.id))
    }

    /// Queued audio plays out first (Readback: a failure pauses the queue, not the sound), then the failure shows.
    private func chunkFailed(at index: Int, message: String) {
        failedIndex = index
        synthTask?.cancel()
        synthTask = nil
        let hasQueuedAudio = !playerDrained && nextToEnqueue > playingIndex && nextToEnqueue > startIndex
        switch state {
        case .speaking, .paused:
            if hasQueuedAudio {
                pendingFailure = message
                return
            }
        default:
            break
        }
        failNow(message)
    }

    private func failNow(_ message: String) {
        generation += 1
        synthTask?.cancel()
        synthTask = nil
        player.stop()
        results = [:]
        pendingFailure = nil
        if failedIndex == nil { failedIndex = playingIndex }
        state = .failed(message)
    }

    private func fail(_ message: String) {
        state = .failed(message)
    }

    private func handle(_ event: SpeechPlaybackEvent, generation: Int) {
        guard generation == self.generation, let utterance else { return }
        switch event {
        case .chunkStarted(let index):
            playingIndex = index
            playerDrained = false
            if case .paused = state { return }
            state = .speaking(chunk: index + 1, of: utterance.chunks.count)
            pump()
        case .drained:
            playerDrained = true
            if let pendingFailure { failNow(pendingFailure) }
        case .finished:
            logger.notice(
                "voice_finished source=\(utterance.source.logName, privacy: .public) chunks=\(utterance.chunks.count, privacy: .public)"
            )
            stop()
        case .interrupted:
            switch state {
            case .speaking(let chunk, let count):
                state = .paused(chunk: chunk, of: count)
            case .preparing:
                state = .paused(chunk: playingIndex + 1, of: utterance.chunks.count)
            default:
                break
            }
        case .failed(let message):
            failedIndex = playingIndex
            failNow(message)
        }
    }

    // MARK: - Messages

    /// Worth another attempt: the network, a rate limit or a server hiccup.
    nonisolated static func isTransient(_ error: Error) -> Bool {
        guard let error = error as? SpeechSynthesisError else { return false }
        switch error {
        case .connectionFailed, .rateLimited: return true
        case .server(let status, _): return status >= 500 && status != 503
        default: return false
        }
    }

    private func message(for error: Error, engineID: String?) -> String {
        if case .unauthorized = error as? SpeechSynthesisError, engineID == VoiceProviderKind.companion.engineID {
            return "The Mac companion did not accept this iPhone's pairing token. "
                + "Pair again in Settings → Mac companion."
        }
        return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

/// The class a reading's source has **as stored now**, for `VoicePlayer`'s `currentPrivacyClass` provider: the
/// transcript's (or document's) `EffectivePrivacyClass`; a deliverable's own class raised by its transcript's; an Ask
/// answer's transcript. nil for the Test voice sentence and for an item that no longer exists (the reading keeps the
/// class it has). A store that cannot be read answers `.clinical`, so a failure never lowers routing.
public enum VoiceSourcePrivacy {
    public static func current(
        for source: VoiceSource,
        transcripts: any TranscriptionStoring,
        deliverables: any DeliverableStoring
    ) async -> PrivacyClass? {
        do {
            switch source {
            case .transcript(let id), .document(let id), .askAnswer(_, let id):
                return try await EffectivePrivacyClass.current(
                    transcriptionID: id, transcripts: transcripts, deliverables: deliverables)
            case .dictationReadBack(let id):
                guard let id else { return nil }
                return try await EffectivePrivacyClass.current(
                    transcriptionID: id, transcripts: transcripts, deliverables: deliverables)
            case .deliverable(let id):
                guard let deliverable = try await deliverables.fetchDeliverable(id: id) else { return nil }
                let transcript = try await EffectivePrivacyClass.current(
                    transcriptionID: deliverable.transcriptionID, transcripts: transcripts, deliverables: deliverables)
                return deliverable.privacyClass.stricter(transcript)
            case .voiceTest:
                return nil
            }
        } catch {
            return .clinical
        }
    }
}
