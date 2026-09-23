// Ported from MacParakeet (GPL-3.0): Sources/MacParakeetCore/Services/Capture/LiveChunkTranscriber.swift @ bbae9e0e
// Changes: one source; each chunk is written to `media/<id>/chunks/chunk-<startMs>-<endMs>.wav` and transcribed with
// `SpeechEngine.transcribe(fileAt:)` inside the scheduler's `.meetingLiveChunk` slot, results applied in sequence
// order (upstream `MeetingChunkResultBuffer`) into `MeetingTranscriptAssembler`; the RMS silence guard from
// `MeetingRecordingService` (≤ 0.00025 skipped); a backpressure drop marks the preview as lagging. Display-only.

import ChirpCore
import Foundation

/// What the Meeting screen shows while recording. Display-only: the saved transcript comes from the final pass.
public struct MeetingLiveUpdate: Sendable, Equatable {
    public var paragraphs: [MeetingLiveParagraph]
    /// Live chunks were dropped because the recognizer fell behind (the final pass still covers everything).
    public var isLagging: Bool

    public init(paragraphs: [MeetingLiveParagraph] = [], isLagging: Bool = false) {
        self.paragraphs = paragraphs
        self.isLagging = isLagging
    }
}

/// Feeds a meeting's samples to a chunker and transcribes each chunk as a `.meetingLiveChunk` job.
///
/// `append` is called by one serial consumer (the coordinator's capture loop). Chunks are queued in the scheduler's
/// background slot, which gives them priority over file jobs but never pre-empts a running one; past 120 pending
/// chunks the scheduler drops the oldest. `finish()` cancels and awaits every chunk job, ends `updates` and removes
/// the chunk folder, so the engine is free for the final pass.
public actor MeetingLiveTranscriber {
    /// Chunks this quiet are silence: not transcribed (upstream guard).
    static let silenceRMS: Float = 0.00025

    /// Internal, not private, so tests can deliver outcomes out of order through `complete(_:_:)`.
    enum Outcome: Sendable {
        case result(SpeechResult, MeetingAudioChunk)
        case skipped(lagging: Bool)
    }

    public nonisolated let updates: AsyncStream<MeetingLiveUpdate>
    private let continuation: AsyncStream<MeetingLiveUpdate>.Continuation
    private let chunker: any MeetingLiveAudioChunking
    private let speech: any SpeechEngine
    private let scheduler: SpeechJobScheduler
    private let chunkFolder: URL
    private let options: SpeechTranscriptionOptions
    private var assembler = MeetingTranscriptAssembler()
    private var tasks: [Int: Task<Void, Never>] = [:]
    private var outcomes: [Int: Outcome] = [:]
    private var nextSequence = 0
    private var nextToApply = 0
    private var isLagging = false
    private var isClosed = false
    private let logger = Log.logger("meeting-live")

    /// Chunks transcribed, skipped as silence, and dropped by backpressure (tests read these).
    public private(set) var transcribedCount = 0
    public private(set) var silentCount = 0
    public private(set) var droppedCount = 0

    public init(
        chunker: any MeetingLiveAudioChunking,
        speech: any SpeechEngine,
        scheduler: SpeechJobScheduler,
        chunkFolder: URL,
        options: SpeechTranscriptionOptions = SpeechTranscriptionOptions()
    ) {
        self.chunker = chunker
        self.speech = speech
        self.scheduler = scheduler
        self.chunkFolder = chunkFolder
        self.options = options
        (updates, continuation) = AsyncStream.makeStream(
            of: MeetingLiveUpdate.self, bufferingPolicy: .bufferingNewest(4))
    }

    public func append(_ samples: [Float]) async {
        guard !isClosed else { return }
        let chunks = await chunker.addSamples(samples)
        for chunk in chunks where !isClosed {
            enqueue(chunk)
        }
    }

    /// Waits until every queued chunk has finished (tests; the app never waits for the preview).
    public func drain() async {
        while let task = tasks.values.first {
            await task.value
        }
    }

    /// Stops taking audio, cancels and awaits every chunk job, ends `updates` and removes the chunk folder.
    public func finish() async {
        guard !isClosed else { return }
        isClosed = true
        let running = Array(tasks.values)
        for task in running { task.cancel() }
        for task in running { await task.value }
        tasks = [:]
        continuation.finish()
        try? FileManager.default.removeItem(at: chunkFolder)
        logger.notice(
            "meeting_live_finished transcribed=\(self.transcribedCount, privacy: .public) silent=\(self.silentCount, privacy: .public) dropped=\(self.droppedCount, privacy: .public)"
        )
    }

    // MARK: - Chunks

    private func enqueue(_ chunk: MeetingAudioChunk) {
        let sequence = nextSequence
        nextSequence += 1
        guard Self.rms(chunk.samples) > Self.silenceRMS else {
            silentCount += 1
            complete(sequence, .skipped(lagging: false))
            return
        }
        let url = chunkFolder.appendingPathComponent("chunk-\(chunk.startMs)-\(chunk.endMs).wav", isDirectory: false)
        do {
            try FileManager.default.createDirectory(at: chunkFolder, withIntermediateDirectories: true)
            try SpeechWAVFile.write(chunk.samples, to: url)
        } catch {
            logger.error("meeting_chunk_write_failed error_type=\(error.logTypeName, privacy: .public)")
            complete(sequence, .skipped(lagging: false))
            return
        }
        let speech = self.speech
        let scheduler = self.scheduler
        let options = self.options
        tasks[sequence] = Task { [weak self] in
            let outcome: Outcome
            do {
                let result = try await scheduler.run(.meetingLiveChunk) {
                    try await speech.transcribe(fileAt: url, options: options, progress: { _ in })
                }
                outcome = .result(result, chunk)
            } catch SpeechJobError.droppedDueToBackpressure {
                outcome = .skipped(lagging: true)
            } catch {
                if !(error is CancellationError), (error as? SpeechEngineError) != .cancelled {
                    Log.logger("meeting-live").notice(
                        "meeting_chunk_failed error_type=\(String(describing: type(of: error)), privacy: .public)")
                }
                outcome = .skipped(lagging: false)
            }
            try? FileManager.default.removeItem(at: url)
            await self?.complete(sequence, outcome)
        }
    }

    /// Records a chunk's outcome and applies every outcome that is next in recording order.
    ///
    /// Outcomes can arrive out of recording order: a chunk task reports only after it has released the recognizer
    /// slot, so the next chunk can transcribe and report first. Internal so tests can reproduce that order.
    func complete(_ sequence: Int, _ outcome: Outcome) {
        tasks[sequence] = nil
        if case .skipped(lagging: true) = outcome { droppedCount += 1 }
        outcomes[sequence] = outcome
        var changed = false
        while let next = outcomes.removeValue(forKey: nextToApply) {
            nextToApply += 1
            switch next {
            case .result(let result, let chunk):
                transcribedCount += 1
                assembler.apply(result, chunk: chunk)
                isLagging = false
                changed = true
            case .skipped(let lagging):
                // Publish a drop as soon as it applies: a later result in this same pass clears the flag, so an
                // end-of-pass update alone would never show it.
                if lagging, !isLagging {
                    isLagging = true
                    publish()
                    changed = false
                }
            }
        }
        if changed { publish() }
    }

    private func publish() {
        guard !isClosed else { return }
        continuation.yield(MeetingLiveUpdate(paragraphs: assembler.paragraphs(), isLagging: isLagging))
    }

    static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for sample in samples { sum += sample * sample }
        return (sum / Float(samples.count)).squareRoot()
    }
}
