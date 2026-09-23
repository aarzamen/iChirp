import ChirpCore
import Dispatch
import Foundation
import Synchronization

#if os(iOS)
import os
#endif

/// Why the engine refused or stopped a run. `LlamaCppLanguageModel` maps each onto a `LanguageModelError` sentence.
public enum LlamaCppEngineError: Error, Equatable, Sendable {
    case notInBuild
    case notDownloaded(displayName: String)
    /// The app left the screen: iOS stops GPU work in the background.
    case inBackground
    case notEnoughMemory(displayName: String, neededBytes: Int64, availableBytes: UInt64)
}

/// The one llama.cpp runtime of the process: at most one model loaded, one generation at a time.
///
/// - Runs on its own serial dispatch queue: reading a long prompt blocks for seconds, which must not hold a thread of
///   Swift's cooperative pool, and llama.cpp contexts are not thread-safe. A second request waits for the first.
/// - Loads a model on first use (only from disk) and **unloads it** after `idleTimeout` without a request, on a memory
///   warning (after the running request, if any), when the app goes to the background, and before its file is deleted.
/// - Foreground only: iOS stops GPU work in the background, so a run stops with `inBackground` when the app leaves the
///   screen, and none starts there.
/// - Checks the free memory the system allows the app (`os_proc_available_memory`) before loading, so a model that
///   cannot fit is refused with a sentence instead of the app being terminated.
public actor LlamaCppEngine {
    public struct Configuration: Sendable {
        public var idleTimeout: Duration
        public var usesGPU: Bool
        public var batchSize: Int
        /// Memory the app may still use, or nil where the system does not say (the Mac, the Simulator).
        public var availableMemory: @Sendable () -> UInt64?

        public init(
            idleTimeout: Duration = .seconds(90),
            usesGPU: Bool = LlamaCppLoader.defaultUsesGPU,
            batchSize: Int = 512,
            availableMemory: @escaping @Sendable () -> UInt64? = LlamaCppEngine.systemAvailableMemory
        ) {
            self.idleTimeout = idleTimeout
            self.usesGPU = usesGPU
            self.batchSize = batchSize
            self.availableMemory = availableMemory
        }
    }

    /// Timing of one run, for the opt-in real-model test and the research note. Never content.
    public struct RunMetrics: Sendable, Equatable {
        public var modelID: String
        /// Seconds to load the model, or nil when it was already loaded.
        public var loadSeconds: Double?
        public var promptTokens: Int
        public var completionTokens: Int
        /// From the start of reading the prompt to the first generated token.
        public var firstTokenSeconds: Double?
        public var promptTokensPerSecond: Double
        /// Generated tokens per second after the first one.
        public var generationTokensPerSecond: Double
    }

    private struct Loaded {
        let modelID: String
        let session: any LlamaSession
    }

    private struct Signals {
        var isForeground = true
        var loadedModelID: String?
    }

    private let queue = DispatchSerialQueue(label: "com.aarzamen.ichirp.llamacpp", qos: .userInitiated)
    public nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    private nonisolated let loader: any LlamaSessionLoading
    private nonisolated let configuration: Configuration
    private nonisolated let signals = Mutex(Signals())
    private let logger = Log.logger("llamacpp")
    private var loaded: Loaded?
    private var idleUnload: Task<Void, Never>?
    private var idleToken = UUID()
    public private(set) var lastRunMetrics: RunMetrics?

    public init(loader: any LlamaSessionLoading = LlamaCppLoader(), configuration: Configuration = Configuration()) {
        self.loader = loader
        self.configuration = configuration
    }

    /// `os_proc_available_memory()` on iOS; nil on the Mac and where the system reports 0 (the Simulator).
    public static let systemAvailableMemory: @Sendable () -> UInt64? = {
        #if os(iOS)
        let available = os_proc_available_memory()
        return available > 0 ? UInt64(available) : nil
        #else
        return nil
        #endif
    }

    // MARK: - State other code may read or set at any time

    public nonisolated var isRuntimeInBuild: Bool { loader.isRuntimeInBuild }

    /// The model in memory now, if any.
    public nonisolated var loadedModelID: String? { signals.withLock { $0.loadedModelID } }

    /// Whether the engine currently believes the app is on screen (`setForeground`); read by `AppLocalLanguageModels`
    /// for diagnostics and by its tests (review N1).
    public nonisolated var isForeground: Bool { signals.withLock { $0.isForeground } }

    /// Whether the app is on screen. Going to the background stops a running generation and unloads the model.
    public nonisolated func setForeground(_ isForeground: Bool) {
        signals.withLock { $0.isForeground = isForeground }
        if !isForeground {
            Task { await self.unload(reason: "background") }
        }
    }

    /// A system memory warning: unloads now, or right after the running request.
    public nonisolated func didReceiveMemoryWarning() {
        Task { await self.unload(reason: "memory_warning") }
    }

    /// Whether `spec` can run now. Never touches the network; `isDownloaded` comes from the model's assets.
    public nonisolated func availability(for spec: LlamaCppModelSpec, isDownloaded: Bool) -> LanguageModelAvailability {
        do {
            try precheck(spec, isDownloaded: isDownloaded)
            return .available
        } catch {
            return .unavailable(LlamaCppLanguageModel.reason(for: error))
        }
    }

    private nonisolated func precheck(_ spec: LlamaCppModelSpec, isDownloaded: Bool) throws {
        guard loader.isRuntimeInBuild else { throw LlamaCppEngineError.notInBuild }
        guard isDownloaded else { throw LlamaCppEngineError.notDownloaded(displayName: spec.displayName) }
        let state = signals.withLock { $0 }
        guard state.isForeground else { throw LlamaCppEngineError.inBackground }
        // With another model loaded, its memory comes back before this one loads; `run` checks again then.
        if state.loadedModelID == nil { try checkMemory(for: spec) }
    }

    private nonisolated func checkMemory(for spec: LlamaCppModelSpec) throws {
        guard let available = configuration.availableMemory() else { return }
        if available < UInt64(spec.estimatedMemoryBytes) {
            throw LlamaCppEngineError.notEnoughMemory(
                displayName: spec.displayName, neededBytes: spec.estimatedMemoryBytes, availableBytes: available)
        }
    }

    // MARK: - Runs

    /// Generates a reply to `request` with `spec`, calling `onText` with each text delta (a leading think block and
    /// the whitespace before the answer are dropped). Returns the usage for the run ledger.
    ///
    /// Throws `LanguageModelError.contextTooLong` before any decoding when the prompt plus `maxOutputTokens` does not fit
    /// the window, `CancellationError` promptly when the calling task is cancelled, `LlamaCppEngineError` when it cannot
    /// run, and `LlamaSessionError` when llama.cpp fails.
    public func run(
        spec: LlamaCppModelSpec,
        modelURL: URL,
        request: GenerationRequest,
        onText: @Sendable (String) -> Void
    ) throws -> GenerationUsage {
        try Task.checkCancellation()
        idleUnload?.cancel()
        idleUnload = nil
        defer { scheduleIdleUnload() }
        try precheck(spec, isDownloaded: true)

        let (session, loadSeconds) = try session(for: spec, at: modelURL)
        do {
            return try generate(
                spec: spec, request: request, session: session, loadSeconds: loadSeconds, onText: onText)
        } catch let error as LlamaSessionError {
            // A failed decode (a Metal command-buffer error, GPU timeout or out of memory) leaves llama.cpp's backend
            // in a sticky error state: every later decode fails until the context is recreated. Drop it now so Retry
            // loads a fresh one (review I1).
            unload(reason: "runtime_error")
            throw error
        }
    }

    private func generate(
        spec: LlamaCppModelSpec,
        request: GenerationRequest,
        session: any LlamaSession,
        loadSeconds: Double?,
        onText: @Sendable (String) -> Void
    ) throws -> GenerationUsage {
        let prompt = try tokens(for: request, format: spec.promptFormat, session: session)
        let window = session.contextTokens
        let room = window - prompt.count
        if let maxOutput = request.maxOutputTokens, maxOutput > room { throw LanguageModelError.contextTooLong }
        guard room >= 16 else { throw LanguageModelError.contextTooLong }
        let maxOutput = request.maxOutputTokens ?? room

        // Clinical requests draw the most likely token every time and nothing penalizes a repeated digit (review I2).
        let sampling = spec.sampling(for: request.privacyClass)
        session.reset(sampling: sampling)
        let clock = ContinuousClock()
        let started = clock.now
        var index = 0
        while index < prompt.count {
            try checkStop()
            let end = min(index + session.batchSize, prompt.count)
            try decode(Array(prompt[index..<end]), session: session)
            index = end
        }
        let promptDone = clock.now

        var decoder = UTF8StreamDecoder()
        var filter = LeadingThinkBlockFilter()
        var generated = 0
        var cached = prompt.count
        var lastToken: Int32
        var firstToken: ContinuousClock.Instant?
        var producedText = false
        var stopReason = "stop"
        // The last few hundred characters of the draft, kept only to tell a real sampling loop from an answer that
        // is simply as long as its length limit (review N3); never logged, never returned.
        var recentText = ""
        while true {
            try checkStop()
            let token = session.sample()
            lastToken = token
            if session.isEndOfGeneration(token) { break }
            generated += 1
            if firstToken == nil { firstToken = clock.now }
            let text = filter.push(decoder.push(session.piece(token)))
            if !text.isEmpty {
                producedText = true
                onText(text)
                recentText = Self.appendToTail(recentText, text)
            }
            if generated >= maxOutput || prompt.count + generated >= window {
                stopReason = "length"
                break
            }
            try decode([token], session: session)
            cached += 1
        }
        // llama.cpp reports a failed Metal command buffer at the *next* decode, so the last token may have been drawn
        // from stale logits. One more decode of it confirms the context was healthy (review I1); it throws otherwise.
        if cached < window { try decode([lastToken], session: session) }
        let tail = filter.push(decoder.finish()) + filter.finish()
        if !tail.isEmpty {
            producedText = true
            onText(tail)
            recentText = Self.appendToTail(recentText, tail)
        }
        let finished = clock.now
        lastRunMetrics = RunMetrics(
            modelID: spec.id, loadSeconds: loadSeconds, promptTokens: prompt.count, completionTokens: generated,
            firstTokenSeconds: firstToken.map { Self.seconds(started, $0) },
            promptTokensPerSecond: Double(prompt.count) / max(Self.seconds(started, promptDone), 1e-9),
            generationTokensPerSecond: firstToken.map {
                Double(max(generated - 1, 0)) / max(Self.seconds($0, finished), 1e-9)
            } ?? 0)
        logger.info(
            "run_finished model=\(spec.id, privacy: .public) prompt_tokens=\(prompt.count, privacy: .public) completion_tokens=\(generated, privacy: .public) stop=\(stopReason, privacy: .public) sampling=\(sampling == .faithful ? "faithful" : "general", privacy: .public)"
        )
        guard producedText else { throw LanguageModelError.streamingError("the on-device model returned no text") }
        // A clinical draft cut off at the length limit is not a finished note (review minor 8), whether it stopped
        // because it was genuinely looping or simply because the answer is as long as the limit allows — a rewrite
        // template asked of a long dictation reaches this honestly, with nothing to repeat (review N3). Say which
        // one happened instead of always blaming a loop, and fail the run either way so nothing half-finished is
        // saved as complete.
        if stopReason == "length", request.privacyClass == .clinical {
            let message =
                Self.looksRepetitive(recentText)
                ? Self.clinicalLengthLimitRepeatingMessage : Self.clinicalLengthLimitMessage
            throw LanguageModelError.providerError(message)
        }
        return GenerationUsage(
            promptTokens: prompt.count, completionTokens: generated, model: spec.id, stopReason: stopReason)
    }

    /// Characters of the draft's tail kept only to check for a repeating pattern (review N3): comfortably more than
    /// `looksRepetitive`'s widest window (`maxPeriod * minRepeats`).
    static let repetitionTailCharacters = 600

    static func appendToTail(_ tail: String, _ text: String) -> String {
        var tail = tail + text
        if tail.count > repetitionTailCharacters {
            tail.removeFirst(tail.count - repetitionTailCharacters)
        }
        return tail
    }

    /// Whether `tail` (the end of a draft) is dominated by a short unit repeated at least `minRepeats` times in a
    /// row — a real sampling loop, not just a long answer. Any window whose length is a whole multiple of a true
    /// period is itself periodic with that period, so checking only the suffix of each candidate length is enough;
    /// it does not need to be aligned to where the repetition began.
    static func looksRepetitive(_ tail: String, minRepeats: Int = 3, minPeriod: Int = 2, maxPeriod: Int = 60) -> Bool {
        let characters = Array(tail)
        let widestUsablePeriod = min(maxPeriod, characters.count / minRepeats)
        guard widestUsablePeriod >= minPeriod else { return false }
        for period in minPeriod...widestUsablePeriod {
            let window = Array(characters.suffix(period * minRepeats))
            let unit = Array(window.prefix(period))
            var index = period
            var matches = true
            while index < window.count {
                let end = min(index + period, window.count)
                if Array(window[index..<end]) != Array(unit.prefix(end - index)) {
                    matches = false
                    break
                }
                index += period
            }
            if matches { return true }
        }
        return false
    }

    static let clinicalLengthLimitMessage =
        "This clinical draft stopped at the model's length limit before it finished. Use a model with a larger "
        + "context window, or shorten the source text."

    static let clinicalLengthLimitRepeatingMessage =
        "This clinical draft stopped at the model's length limit before it finished, and the end of it was "
        + "repeating itself. Use a model with a larger context window, or shorten the source text."

    /// Frees `modelID` if it is loaded (before its file is deleted). A running request finishes first.
    public func release(modelID: String) {
        guard loaded?.modelID == modelID else { return }
        unload(reason: "release")
    }

    /// Frees the loaded model now (a running request has already finished: requests do not interleave).
    public func unload(reason: String) {
        idleUnload?.cancel()
        idleUnload = nil
        guard let modelID = loaded?.modelID else { return }
        loaded = nil
        signals.withLock { $0.loadedModelID = nil }
        logger.notice("model_unloaded model=\(modelID, privacy: .public) reason=\(reason, privacy: .public)")
    }

    // MARK: - Private

    private func session(for spec: LlamaCppModelSpec, at url: URL) throws -> (any LlamaSession, Double?) {
        if let loaded, loaded.modelID == spec.id { return (loaded.session, nil) }
        unload(reason: "switch")
        try checkMemory(for: spec)
        let clock = ContinuousClock()
        let started = clock.now
        let options = LlamaLoadOptions(
            contextTokens: spec.contextTokens, batchSize: configuration.batchSize, usesGPU: configuration.usesGPU)
        let session = try loader.loadSession(modelAt: url, options: options)
        let seconds = Self.seconds(started, clock.now)
        loaded = Loaded(modelID: spec.id, session: session)
        signals.withLock { $0.loadedModelID = spec.id }
        logger.notice(
            "model_loaded model=\(spec.id, privacy: .public) seconds=\(seconds, privacy: .public) gpu=\(self.configuration.usesGPU, privacy: .public)"
        )
        return (session, seconds)
    }

    /// Control pieces with special tokens recognised; content (instructions, transcript) as plain text only.
    private func tokens(for request: GenerationRequest, format: LlamaPromptFormat, session: any LlamaSession) throws
        -> [Int32]
    {
        var tokens: [Int32] = []
        for (offset, piece) in format.pieces(system: request.system, prompt: request.prompt).enumerated() {
            switch piece {
            case .control(let text):
                tokens += try session.tokenize(text, addSpecial: offset == 0, parseSpecial: true)
            case .content(let text):
                tokens += try session.tokenize(text, addSpecial: offset == 0, parseSpecial: false)
            }
        }
        return tokens
    }

    private func checkStop() throws {
        try Task.checkCancellation()
        guard signals.withLock({ $0.isForeground }) else { throw LlamaCppEngineError.inBackground }
    }

    private func decode(_ tokens: [Int32], session: any LlamaSession) throws {
        do {
            try session.decode(tokens)
        } catch LlamaSessionError.decodeFailed where !signals.withLock({ $0.isForeground }) {
            // The GPU refused work because the app left the screen.
            throw LlamaCppEngineError.inBackground
        }
    }

    private func scheduleIdleUnload() {
        guard loaded != nil else { return }
        let token = UUID()
        idleToken = token
        let timeout = configuration.idleTimeout
        idleUnload = Task {
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            self.unloadIfIdle(token: token)
        }
    }

    private func unloadIfIdle(token: UUID) {
        guard idleToken == token else { return }
        unload(reason: "idle")
    }

    private static func seconds(_ start: ContinuousClock.Instant, _ end: ContinuousClock.Instant) -> Double {
        let duration = end - start
        return Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}
