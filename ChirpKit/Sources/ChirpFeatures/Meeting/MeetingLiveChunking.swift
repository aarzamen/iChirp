// Ported from MacParakeet (GPL-3.0): Sources/MacParakeetCore/Audio/SpeechBoundaryMeetingLiveAudioChunker.swift @ bbae9e0e
// Changes: also ports `Audio/AudioChunker.swift` (the fixed 5 s / 1 s-overlap chunker, now draining every full window
// of a large ingest instead of one per call). The VAD chunker keeps upstream's contiguous sample accounting,
// lockstep VAD buffering, 2–10 s cuts on speech end, 0.25 s overlap after a forced cut, silence-window drops and the
// fixed fallback after 3 consecutive VAD errors; it talks to a `ChirpCore.VoiceActivityStream` instead of
// `MeetingVoiceActivityDetecting` + an opaque state, and uses OSLog through `Log`.

import ChirpCore
import Foundation

/// A slice of the recording for one live-preview pass. `startMs` is the absolute position of `samples[0]` in the
/// recording (paused time excluded), so the assembler can place and de-duplicate words.
public struct MeetingAudioChunk: Sendable, Equatable {
    public let samples: [Float]
    public let startMs: Int
    public let endMs: Int

    public init(samples: [Float], startMs: Int, endMs: Int) {
        self.samples = samples
        self.startMs = startMs
        self.endMs = endMs
    }

    public var durationMs: Int { endMs - startMs }
}

/// Counters for tests (no audio, no text).
public struct MeetingLiveChunkingDiagnostics: Sendable, Equatable {
    public var chunksEmitted = 0
    public var speechEndEvents = 0
    public var forceEmits = 0
    public var droppedSilenceWindows = 0
    public var vadErrors = 0
    public var fellBackToFixed = false
}

/// Cuts the live sample stream into chunks. One caller at a time (the live transcriber's serial feed).
public protocol MeetingLiveAudioChunking: Actor {
    func addSamples(_ samples: [Float]) async -> [MeetingAudioChunk]
    /// The unfinished tail at stop, if it is worth transcribing.
    func flush() async -> MeetingAudioChunk?
    var diagnostics: MeetingLiveChunkingDiagnostics { get }
}

private enum ChunkMath {
    static let sampleRate = SpeechAudio.sampleRate

    static func ms(_ sample: Int) -> Int { sample * 1000 / sampleRate }
}

/// Upstream `AudioChunker`: fixed 5 s windows with 1 s overlap; a tail of at least 0.5 s is flushed.
public actor FixedMeetingLiveAudioChunker: MeetingLiveAudioChunking {
    static let window = 5 * ChunkMath.sampleRate
    static let overlap = 1 * ChunkMath.sampleRate
    static let flushMinimum = 8_000

    private var buffer: [Float] = []
    private var bufferStartSample = 0
    private var diag = MeetingLiveChunkingDiagnostics()

    public init() {}

    public var diagnostics: MeetingLiveChunkingDiagnostics { diag }

    public func addSamples(_ samples: [Float]) -> [MeetingAudioChunk] {
        buffer.append(contentsOf: samples)
        var out: [MeetingAudioChunk] = []
        while buffer.count >= Self.window {
            out.append(emit(length: Self.window, advance: Self.window - Self.overlap))
        }
        return out
    }

    public func flush() -> MeetingAudioChunk? {
        guard buffer.count >= Self.flushMinimum else {
            bufferStartSample += buffer.count
            buffer = []
            return nil
        }
        return emit(length: buffer.count, advance: buffer.count)
    }

    private func emit(length: Int, advance: Int) -> MeetingAudioChunk {
        let chunk = MeetingAudioChunk(
            samples: Array(buffer.prefix(length)), startMs: ChunkMath.ms(bufferStartSample),
            endMs: ChunkMath.ms(bufferStartSample + length))
        buffer.removeFirst(min(advance, buffer.count))
        bufferStartSample += advance
        diag.chunksEmitted += 1
        return chunk
    }
}

/// Live-preview chunker that cuts at VAD speech boundaries (upstream `SpeechBoundaryMeetingLiveAudioChunker`).
///
/// **Contiguous sample accounting.** Chunks tile the recording with no gaps, so `lastEmittedSample` is always the
/// absolute index of `buffer[0]` and a chunk's `startMs` is the true position of its first sample.
///
/// **Lockstep buffering.** Incoming samples wait in `pendingVAD` and move into `buffer` only once fed to VAD in exact
/// windows, so force-emit and silence-drop decisions never act on audio VAD has not examined.
///
/// Silence between utterances becomes leading silence of the next chunk. The only overlap is a 0.25 s tail re-fed
/// after a forced (10 s) cut, which lands mid-word; the assembler's de-duplication drops the repeated words.
public actor SpeechBoundaryMeetingLiveAudioChunker: MeetingLiveAudioChunking {
    private static let minChunkSamples = 2 * ChunkMath.sampleRate
    private static let maxChunkSamples = 10 * ChunkMath.sampleRate
    private static let forceEmitTailOverlap = ChunkMath.sampleRate / 4
    private static let flushMinSamples = ChunkMath.sampleRate / 2
    static let maxConsecutiveVADErrors = 3

    private let vad: any VoiceActivityStream
    private let vadWindow: Int
    private var buffer: [Float] = []
    private var pendingVAD: [Float] = []
    private var lastEmittedSample = 0
    private var sawSpeechSinceLastEmit = false
    private var consecutiveVADErrors = 0
    private var fellBackToFixed = false
    private var diag = MeetingLiveChunkingDiagnostics()
    private let logger = Log.logger("meeting-chunker")

    /// - Parameter windowSize: the detector's window (`VoiceActivityDetecting.windowSize`, Silero 4096).
    public init(vad: any VoiceActivityStream, windowSize: Int = 4_096) {
        self.vad = vad
        self.vadWindow = max(1, windowSize)
    }

    public var diagnostics: MeetingLiveChunkingDiagnostics { diag }

    public func addSamples(_ samples: [Float]) async -> [MeetingAudioChunk] {
        guard !samples.isEmpty else { return [] }
        if fellBackToFixed {
            buffer.append(contentsOf: samples)
            return drainFixed()
        }
        pendingVAD.append(contentsOf: samples)
        var emitted: [MeetingAudioChunk] = []
        while pendingVAD.count >= vadWindow {
            let window = Array(pendingVAD.prefix(vadWindow))
            pendingVAD.removeFirst(vadWindow)
            // Into the emittable buffer before processing, so a speech-end cut from this window has its audio.
            buffer.append(contentsOf: window)
            await process(window: window, into: &emitted)
            if fellBackToFixed {
                buffer.append(contentsOf: pendingVAD)
                pendingVAD.removeAll()
                emitted.append(contentsOf: drainFixed())
                return emitted
            }
            if let forced = maybeForceEmitOrDropSilence() {
                emitted.append(forced)
            }
        }
        return emitted
    }

    public func flush() async -> MeetingAudioChunk? {
        if fellBackToFixed {
            return flushFixed()
        }
        // Feed the sub-window tail so a speech end in the last < 256 ms is still recognized.
        if !pendingVAD.isEmpty {
            let tail = pendingVAD
            pendingVAD.removeAll()
            buffer.append(contentsOf: tail)
            if let event = try? await vad.process(tail) {
                switch event {
                case .speechStart:
                    sawSpeechSinceLastEmit = true
                case .speechEnd(let cutSample):
                    diag.speechEndEvents += 1
                    if let chunk = emitAtSpeechEnd(cutSample: cutSample) {
                        return chunk
                    }
                }
            }
        }
        guard sawSpeechSinceLastEmit, buffer.count >= Self.flushMinSamples else { return nil }
        return makeChunk(length: buffer.count, tailOverlap: 0)
    }

    // MARK: - VAD streaming

    private func process(window: [Float], into emitted: inout [MeetingAudioChunk]) async {
        do {
            let event = try await vad.process(window)
            consecutiveVADErrors = 0
            switch event {
            case .speechStart:
                sawSpeechSinceLastEmit = true
            case .speechEnd(let cutSample):
                diag.speechEndEvents += 1
                if let chunk = emitAtSpeechEnd(cutSample: cutSample) {
                    emitted.append(chunk)
                }
            case nil:
                break
            }
        } catch {
            diag.vadErrors += 1
            consecutiveVADErrors += 1
            logger.error(
                "meeting_vad_stream_error consecutive=\(self.consecutiveVADErrors, privacy: .public) error_type=\(String(describing: type(of: error)), privacy: .public)"
            )
            if consecutiveVADErrors >= Self.maxConsecutiveVADErrors {
                fellBackToFixed = true
                diag.fellBackToFixed = true
                logger.notice("meeting_vad_fallback_to_fixed reason=vad_error")
            }
        }
    }

    /// Emits `[lastEmittedSample, cutSample)` when a speech segment ends (the cut is absolute and may lie behind the
    /// current position).
    private func emitAtSpeechEnd(cutSample: Int) -> MeetingAudioChunk? {
        guard sawSpeechSinceLastEmit else { return nil }
        let length = cutSample - lastEmittedSample
        if length <= 0 {
            // The boundary is behind what was already emitted (a forced cut passed it): speech is over.
            sawSpeechSinceLastEmit = false
            return nil
        }
        // Shorter than 2 s: keep buffering; the next speech end extends the segment.
        guard length >= Self.minChunkSamples, length <= buffer.count else { return nil }
        let chunk = makeChunk(length: length, tailOverlap: 0)
        sawSpeechSinceLastEmit = false
        return chunk
    }

    /// At the 10 s cap: a forced cut (keeping a 0.25 s tail) after speech, else drop the silence down to one window.
    private func maybeForceEmitOrDropSilence() -> MeetingAudioChunk? {
        guard buffer.count >= Self.maxChunkSamples else { return nil }
        guard sawSpeechSinceLastEmit else {
            let drop = buffer.count - vadWindow
            if drop > 0 {
                buffer.removeFirst(drop)
                lastEmittedSample += drop
                diag.droppedSilenceWindows += 1
            }
            return nil
        }
        diag.forceEmits += 1
        return makeChunk(length: Self.maxChunkSamples, tailOverlap: Self.forceEmitTailOverlap)
    }

    /// Emits `buffer[0..<length]`, then advances by `length - tailOverlap`. Times come only from sample counts.
    private func makeChunk(length: Int, tailOverlap: Int) -> MeetingAudioChunk {
        let chunk = MeetingAudioChunk(
            samples: Array(buffer.prefix(length)), startMs: ChunkMath.ms(lastEmittedSample),
            endMs: ChunkMath.ms(lastEmittedSample + length))
        let advance = max(0, length - tailOverlap)
        buffer.removeFirst(min(advance, buffer.count))
        lastEmittedSample += advance
        diag.chunksEmitted += 1
        return chunk
    }

    // MARK: - Fixed fallback (same counters, so times stay monotonic across the switch)

    private func drainFixed() -> [MeetingAudioChunk] {
        var out: [MeetingAudioChunk] = []
        while buffer.count >= FixedMeetingLiveAudioChunker.window {
            out.append(
                makeChunk(
                    length: FixedMeetingLiveAudioChunker.window, tailOverlap: FixedMeetingLiveAudioChunker.overlap))
        }
        return out
    }

    private func flushFixed() -> MeetingAudioChunk? {
        guard buffer.count >= FixedMeetingLiveAudioChunker.flushMinimum else {
            lastEmittedSample += buffer.count
            buffer = []
            return nil
        }
        return makeChunk(length: buffer.count, tailOverlap: 0)
    }
}
