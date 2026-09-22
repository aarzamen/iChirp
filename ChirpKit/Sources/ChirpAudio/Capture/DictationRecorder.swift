// Ported from MacParakeet (GPL-3.0): Sources/MacParakeetCore/Audio/AudioRecorder.swift @ bbae9e0e
// Changes: the dictation recording path only — subscribe to the shared stream, copy each tap buffer off the render
// thread, keep channel 0 under voice processing (else downmix), convert to 16 kHz mono Float32 WAV, smoothed level,
// 0.3 s minimum. Writes to the caller's `media/<id>/dictation.wav` instead of `$TMPDIR`; no pre-roll ring, health
// watchdogs or diagnostics files. Live samples go out on an `AsyncStream` instead of a `DictationAudioSampleSink`.

import AVFoundation
import ChirpCore
import Foundation
import Synchronization

/// `AudioCapturing` for dictation: the shared microphone stream into a 16 kHz mono Float32 WAV.
///
/// The render-thread tap only copies the buffer; conversion, writing, level and the update stream run on one serial
/// processing queue. `stop` unsubscribes, waits for that queue, flushes and closes the file, so the returned
/// duration is exactly what the file holds.
public final class DictationRecorder: AudioCapturing {
    private struct Active {
        let token: SharedMicrophoneStream.SubscriberToken
        let writer: RecordingWriter
        let continuation: AsyncStream<CaptureUpdate>.Continuation
    }

    private let stream: SharedMicrophoneStream
    private let session: AudioSessionController
    private let voiceProcessing: Bool
    private let active = Mutex<Active?>(nil)
    /// Serializes start/stop/cancel so two calls never interleave their awaits.
    private let lifecycle = AsyncLifecycleLock()
    private let processingQueue = DispatchQueue(label: "com.aarzamen.ichirp.recorder", qos: .userInitiated)
    private let logger = Log.logger("recorder")

    /// - Parameter voiceProcessing: whether the input runs Apple's voice processing (then only channel 0 is the
    ///   processed signal). iChirp does not enable it in M2; the rule is kept from upstream for when it does.
    public init(stream: SharedMicrophoneStream, session: AudioSessionController, voiceProcessing: Bool = false) {
        self.stream = stream
        self.session = session
        self.voiceProcessing = voiceProcessing
    }

    public func microphonePermission() -> MicrophonePermission {
        session.microphonePermission()
    }

    public func requestMicrophonePermission() async -> Bool {
        await session.requestMicrophonePermission()
    }

    public func start(recordingTo url: URL) async throws -> AsyncStream<CaptureUpdate> {
        try await lifecycle.run { [self] in
            guard active.withLock({ $0 == nil }) else { throw AudioCaptureError.alreadyRecording }
            let writer: RecordingWriter
            do {
                writer = try RecordingWriter(url: url, extractChannelZero: voiceProcessing)
            } catch {
                throw AudioCaptureError.startFailed(error.localizedDescription)
            }
            let (updates, continuation) = AsyncStream.makeStream(
                of: CaptureUpdate.self, bufferingPolicy: .bufferingNewest(4_000))
            writer.continuation = continuation
            let queue = processingQueue
            do {
                let token = try await stream.subscribe(
                    onEvent: { event in
                        // Through the processing queue so an event never overtakes the audio before it.
                        queue.async { continuation.yield(.event(event)) }
                    },
                    handler: { buffer, _ in
                        guard let copy = copyPCMBufferForAsyncUse(buffer) else { return }
                        let box = UncheckedBuffer(copy)
                        queue.async { writer.process(box.buffer) }
                    })
                active.withLock { $0 = Active(token: token, writer: writer, continuation: continuation) }
                logger.notice("recording_started")
                return updates
            } catch {
                continuation.finish()
                writer.discard()
                throw AudioCaptureError.startFailed(Self.message(for: error))
            }
        }
    }

    public func resume() async throws {
        guard active.withLock({ $0 != nil }) else { throw AudioCaptureError.notRecording }
        try await stream.resume()
    }

    public func stop() async throws -> RecordedAudio {
        try await lifecycle.run { [self] in
            guard let current = active.withLock({ $0 }) else { throw AudioCaptureError.notRecording }
            let written = await finish(current)
            active.withLock { $0 = nil }
            guard written.sampleCount >= SpeechAudio.minimumSamples else {
                try? FileManager.default.removeItem(at: written.url)
                logger.notice("recording_too_short samples=\(written.sampleCount, privacy: .public)")
                throw AudioCaptureError.tooShort
            }
            logger.notice("recording_stopped ms=\(written.durationMs, privacy: .public)")
            return written
        }
    }

    public func cancel() async {
        try? await lifecycle.run { [self] in
            guard let current = active.withLock({ $0 }) else { return }
            let written = await finish(current)
            active.withLock { $0 = nil }
            try? FileManager.default.removeItem(at: written.url)
            logger.notice("recording_cancelled")
        }
    }

    /// Unsubscribes (no more taps), drains the processing queue, closes the file and ends the update stream.
    private func finish(_ current: Active) async -> RecordedAudio {
        await stream.unsubscribe(current.token)
        let writer = current.writer
        let recorded = await withCheckedContinuation { (continuation: CheckedContinuation<RecordedAudio, Never>) in
            processingQueue.async {
                continuation.resume(returning: writer.close())
            }
        }
        current.continuation.finish()
        return recorded
    }

    private static func message(for error: any Error) -> String {
        (error as? any LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

/// The file side of one recording. Used only on the recorder's processing queue (hence `@unchecked Sendable`).
final class RecordingWriter: @unchecked Sendable {
    static let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: Double(SpeechAudio.sampleRate), channels: 1, interleaved: false)!

    let url: URL
    var continuation: AsyncStream<CaptureUpdate>.Continuation?
    private var file: AVAudioFile?
    private let converter = SpeechRateConverter(outputFormat: RecordingWriter.outputFormat)
    private let extractChannelZero: Bool
    private var sampleCount = 0
    private var level: Float = 0
    private let logger = Log.logger("recorder")

    init(url: URL, extractChannelZero: Bool) throws {
        self.url = url
        self.extractChannelZero = extractChannelZero
        try? FileManager.default.removeItem(at: url)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Double(SpeechAudio.sampleRate),
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
        ]
        file = try AVAudioFile(
            forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    }

    func process(_ buffer: AVAudioPCMBuffer) {
        guard let file,
            let mono = microphoneCaptureMonoBuffer(from: buffer, extractVoiceProcessingChannelZero: extractChannelZero),
            let converted = converter.convert(mono), converted.frameLength > 0,
            let data = converted.floatChannelData?[0]
        else { return }
        do {
            try file.write(from: converted)
        } catch {
            logger.error("write_failed error_type=\(String(describing: type(of: error)), privacy: .public)")
            return
        }
        let count = Int(converted.frameLength)
        sampleCount += count
        let samples = Array(UnsafeBufferPointer(start: data, count: count))
        var sum: Float = 0
        for sample in samples { sum += sample * sample }
        // Upstream's display level: RMS × 5, capped, lightly smoothed.
        let normalized = min(sqrtf(sum / Float(count)) * 5, 1)
        level = level * 0.3 + normalized * 0.7
        continuation?.yield(.samples(samples))
        continuation?.yield(.level(level))
    }

    /// Closes the file and returns what it holds.
    func close() -> RecordedAudio {
        file?.close()
        file = nil
        let durationMs = Int((Double(sampleCount) * 1000 / Double(SpeechAudio.sampleRate)).rounded())
        return RecordedAudio(url: url, durationMs: durationMs, sampleCount: sampleCount)
    }

    /// Closes and deletes a file that never received audio (a failed start).
    func discard() {
        file?.close()
        file = nil
        try? FileManager.default.removeItem(at: url)
    }
}

/// Carries a copied buffer to the processing queue. The copy is owned by that one hop, so no data race.
struct UncheckedBuffer: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
}

/// Runs async operations one at a time, in call order.
actor AsyncLifecycleLock {
    private var tail: Task<Void, Never>?

    func run<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let previous = tail
        let task = Task<T, any Error> {
            await previous?.value
            return try await operation()
        }
        tail = Task { _ = try? await task.value }
        return try await task.value
    }
}
