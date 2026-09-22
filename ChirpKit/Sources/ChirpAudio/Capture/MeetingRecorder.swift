// Ported from MacParakeet (GPL-3.0): Sources/MacParakeetCore/Audio/MeetingAudioStorageWriter.swift @ bbae9e0e
// Changes: one microphone source; writes a 16 kHz mono 16-bit PCM CAF through `AVAudioFile` instead of fragmented
// AAC through `AVAssetWriter` (M3 Step 1: a killed CAF stays readable to the last buffer, see
// docs/research/2026-09-22-meeting-crash-format.md); pause and mute from `MeetingRecordingService`; capture plumbing
// shared with `DictationRecorder` (shared stream, copy off the render thread, channel 0 / downmix, 16 kHz convert).

import AVFoundation
import ChirpCore
import Foundation
import Synchronization

/// `MeetingAudioCapturing`: the shared microphone stream into `media/<id>/meeting.caf`.
///
/// The render-thread tap only copies each buffer; converting, writing, the level and the update stream run on one
/// serial processing queue, and pause/mute changes go through that queue too, so they apply exactly between two
/// buffers. Nothing here deletes audio: `stop` and `cancel` both close the file and keep it.
public final class MeetingRecorder: MeetingAudioCapturing {
    private struct Active {
        let token: SharedMicrophoneStream.SubscriberToken
        let writer: MeetingAudioWriter
        let continuation: AsyncStream<CaptureUpdate>.Continuation
    }

    private let stream: SharedMicrophoneStream
    private let session: AudioSessionController
    private let voiceProcessing: Bool
    private let active = Mutex<Active?>(nil)
    private let lifecycle = AsyncLifecycleLock()
    private let processingQueue = DispatchQueue(label: "com.aarzamen.ichirp.meeting-recorder", qos: .userInitiated)
    private let logger = Log.logger("meeting-recorder")

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
            let writer: MeetingAudioWriter
            do {
                writer = try MeetingAudioWriter(url: url, extractChannelZero: voiceProcessing)
            } catch {
                throw AudioCaptureError.startFailed(error.localizedDescription)
            }
            // An hour of 4096-frame buffers is far below this; a slow consumer loses old levels, never file audio.
            let (updates, continuation) = AsyncStream.makeStream(
                of: CaptureUpdate.self, bufferingPolicy: .bufferingNewest(4_000))
            writer.continuation = continuation
            let queue = processingQueue
            do {
                let token = try await stream.subscribe(
                    onEvent: { event in
                        queue.async { continuation.yield(.event(event)) }
                    },
                    handler: { buffer, _ in
                        guard let copy = copyPCMBufferForAsyncUse(buffer) else { return }
                        let box = UncheckedBuffer(copy)
                        queue.async { writer.process(box.buffer) }
                    })
                active.withLock { $0 = Active(token: token, writer: writer, continuation: continuation) }
                logger.notice("meeting_recording_started")
                return updates
            } catch {
                continuation.finish()
                // Nothing reached the file yet; closing keeps an empty, valid CAF for the coordinator to clean up.
                _ = writer.close()
                throw AudioCaptureError.startFailed(Self.message(for: error))
            }
        }
    }

    public func setPaused(_ paused: Bool) async {
        await onProcessingQueue { $0.isPaused = paused }
    }

    public func setMuted(_ muted: Bool) async {
        await onProcessingQueue { $0.isMuted = muted }
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
            logger.notice("meeting_recording_stopped ms=\(written.durationMs, privacy: .public)")
            return written
        }
    }

    public func cancel() async {
        try? await lifecycle.run { [self] in
            guard let current = active.withLock({ $0 }) else { return }
            _ = await finish(current)
            active.withLock { $0 = nil }
            logger.notice("meeting_recording_cancelled")
        }
    }

    /// Runs `change` on the active writer from the processing queue (so it lands between two buffers).
    private func onProcessingQueue(_ change: @escaping @Sendable (MeetingAudioWriter) -> Void) async {
        guard let writer = active.withLock({ $0?.writer }) else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            processingQueue.async {
                change(writer)
                continuation.resume()
            }
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

/// The file side of one meeting. Used only on the recorder's processing queue (hence `@unchecked Sendable`).
final class MeetingAudioWriter: @unchecked Sendable {
    /// What the file stores: 16 kHz mono 16-bit signed-integer PCM (the contract's `meeting.caf`).
    static var fileSettings: [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Double(SpeechAudio.sampleRate),
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
    }

    let url: URL
    var continuation: AsyncStream<CaptureUpdate>.Continuation?
    var isPaused = false
    var isMuted = false
    private var file: AVAudioFile?
    private let converter = SpeechRateConverter(outputFormat: RecordingWriter.outputFormat)
    private let extractChannelZero: Bool
    private var sampleCount = 0
    private var level: Float = 0
    private var writeFailed = false
    private let logger = Log.logger("meeting-recorder")

    /// Creates the file. Refuses to replace an existing recording: a meeting's audio is never overwritten.
    init(url: URL, extractChannelZero: Bool) throws {
        self.url = url
        self.extractChannelZero = extractChannelZero
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw CocoaError(.fileWriteFileExists)
        }
        // The file is written in the processing format (Float32) and stored as 16-bit PCM by `AVAudioFile`.
        file = try AVAudioFile(
            forWriting: url, settings: Self.fileSettings, commonFormat: .pcmFormatFloat32, interleaved: false)
    }

    func process(_ buffer: AVAudioPCMBuffer) {
        guard let file, !writeFailed, !isPaused,
            let mono = microphoneCaptureMonoBuffer(from: buffer, extractVoiceProcessingChannelZero: extractChannelZero),
            let converted = converter.convert(mono), converted.frameLength > 0,
            let data = converted.floatChannelData?[0]
        else { return }
        let count = Int(converted.frameLength)
        if isMuted {
            data.update(repeating: 0, count: count)
        }
        do {
            try file.write(from: converted)
        } catch {
            // Usually a full disk. Everything written so far stays readable; say so once and stop writing.
            writeFailed = true
            logger.error("meeting_write_failed error_type=\(String(describing: type(of: error)), privacy: .public)")
            continuation?.yield(
                .event(
                    .failed(
                        message:
                            "Parakeet could not save more audio (the iPhone may be out of storage). Everything up to "
                            + "now is saved. Stop to transcribe it.")))
            return
        }
        sampleCount += count
        let samples = Array(UnsafeBufferPointer(start: data, count: count))
        var sum: Float = 0
        for sample in samples { sum += sample * sample }
        let normalized = isMuted ? 0 : min(sqrtf(sum / Float(count)) * 5, 1)
        level = level * 0.3 + normalized * 0.7
        continuation?.yield(.samples(samples))
        continuation?.yield(.level(level))
    }

    /// Closes the file and returns what it holds. Never deletes it.
    func close() -> RecordedAudio {
        file?.close()
        file = nil
        let durationMs = Int((Double(sampleCount) * 1000 / Double(SpeechAudio.sampleRate)).rounded())
        return RecordedAudio(url: url, durationMs: durationMs, sampleCount: sampleCount)
    }
}
