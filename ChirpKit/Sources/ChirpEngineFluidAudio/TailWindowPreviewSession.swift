// Ported from MacParakeet (GPL-3.0): Sources/MacParakeetCore/Services/Dictation/DictationService.swift @ bbae9e0e
// Changes: `beginDisplayPreviewIfAvailable`'s tail-window loop (1 s interval, last 15 s, one pass at a time) as a
// `ChirpCore.LiveSpeechSession` actor driven by a ticker instead of the sample stream, each pass through the
// scheduler's `.dictation` slot (upstream: `STTScheduler.transcribeDictationPreview`), cancelled and drained on
// finish. No generation resets (iChirp has no pre-roll to discard) and no diagnostics files.

import ChirpCore
import Foundation

/// Live preview for a batch engine: about every second, transcribe the last ~15 s of audio and publish the text.
///
/// - **Single-flight.** A tick that arrives while a pass runs is skipped, never queued: a queue of previews would
///   starve the final pass (plan 011 maintenance note).
/// - A tick with no new audio since the last pass, or with less than half a second of audio, does nothing.
/// - Each pass runs through `SpeechJobScheduler.run(.dictation)`, so it never waits behind a background file job.
/// - `finish()` / `cancel()` stop the ticker, cancel the pass in flight, **wait for it**, and end `updates`; after
///   that nothing of this session runs, so the final pass gets the engine at once.
/// - Failed passes are logged and skipped: the preview is display-only.
actor TailWindowPreviewSession: LiveSpeechSession {
    typealias Transcribe = @Sendable (_ window: [Float]) async throws -> String

    nonisolated let updates: AsyncStream<String>
    private let continuation: AsyncStream<String>.Continuation
    private let scheduler: SpeechJobScheduler
    private let transcribe: Transcribe
    private let windowSampleCount: Int
    private let minimumSampleCount: Int
    private var tail: [Float] = []
    private var appendedTotal = 0
    private var lastPassTotal = 0
    private var inFlight: Task<Void, Never>?
    private var ticker: Task<Void, Never>?
    private var isClosed = false
    private let logger = Log.logger("live-preview")

    /// Passes started and ticks skipped because one was running (tests read these).
    private(set) var passCount = 0
    private(set) var skippedTicks = 0
    /// No pass is running.
    var isIdle: Bool { inFlight == nil }
    /// `finish()` or `cancel()` has begun.
    var isFinishing: Bool { isClosed }

    init(
        scheduler: SpeechJobScheduler,
        windowSeconds: Double = 15,
        minimumSeconds: Double = 0.5,
        transcribe: @escaping Transcribe
    ) {
        self.scheduler = scheduler
        self.transcribe = transcribe
        self.windowSampleCount = Int(windowSeconds * Double(SpeechAudio.sampleRate))
        self.minimumSampleCount = Int(minimumSeconds * Double(SpeechAudio.sampleRate))
        (updates, continuation) = AsyncStream.makeStream(of: String.self, bufferingPolicy: .bufferingNewest(8))
    }

    /// Starts ticking every `interval` (upstream default 1 s). Tests call `tick()` themselves instead.
    func startTicking(every interval: Duration = .seconds(1)) {
        guard ticker == nil, !isClosed else { return }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self else { return }
                await self.tick()
            }
        }
    }

    func append(_ samples: [Float]) {
        guard !isClosed, !samples.isEmpty else { return }
        tail.append(contentsOf: samples)
        appendedTotal += samples.count
        if tail.count > windowSampleCount {
            tail.removeFirst(tail.count - windowSampleCount)
        }
    }

    /// One preview opportunity: starts a pass over the current window unless one is running (skipped), nothing new
    /// arrived, or the window is too short.
    func tick() {
        guard !isClosed else { return }
        guard inFlight == nil else {
            skippedTicks += 1
            return
        }
        guard appendedTotal > lastPassTotal, tail.count >= minimumSampleCount else { return }
        lastPassTotal = appendedTotal
        passCount += 1
        let window = tail
        let scheduler = self.scheduler
        let transcribe = self.transcribe
        inFlight = Task { [weak self] in
            let text: String?
            do {
                text = try await scheduler.run(.dictation) { try await transcribe(window) }
            } catch {
                if !(error is CancellationError), (error as? SpeechEngineError) != .cancelled {
                    Log.logger("live-preview").notice(
                        "preview_pass_failed error_type=\(String(describing: type(of: error)), privacy: .public)")
                }
                text = nil
            }
            await self?.passEnded(text)
        }
    }

    private func passEnded(_ text: String?) {
        inFlight = nil
        guard !isClosed, let text else { return }
        continuation.yield(text)
    }

    func finish() async {
        await close()
    }

    func cancel() async {
        await close()
    }

    private func close() async {
        guard !isClosed else {
            await inFlight?.value
            return
        }
        isClosed = true
        ticker?.cancel()
        ticker = nil
        tail = []
        let pass = inFlight
        pass?.cancel()
        await pass?.value
        continuation.finish()
        logger.notice(
            "preview_closed passes=\(self.passCount, privacy: .public) skipped=\(self.skippedTicks, privacy: .public)")
    }
}
