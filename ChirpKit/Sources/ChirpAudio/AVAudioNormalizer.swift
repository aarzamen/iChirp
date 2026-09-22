// Replaces upstream Audio/AudioFileConverter.swift (FFmpeg subprocess) with AVAssetReader.
// iChirp has no bundled FFmpeg binary on iOS, so normalization goes through AVFoundation's
// native decode path instead of shelling out to a subprocess.

import AVFoundation
import ChirpCore
import CoreMedia
import Foundation
import Synchronization

/// Errors from `AVAudioNormalizer`.
public enum AudioNormalizationError: Error, Equatable {
    /// `sourceURL` has no audio track AVFoundation can decode.
    case noAudioTrack
    /// `AVAssetReader` (or the output file) failed; the message is AVFoundation's own
    /// description.
    case readerFailed(String)
}

/// Decodes any AVFoundation-readable audio or video file into 16 kHz mono Float32 WAV.
///
/// Streams `CMSampleBuffer`s from an `AVAssetReaderAudioMixOutput` straight into an
/// `AVAudioFile` one buffer at a time — the source is never loaded into memory as a whole,
/// and `normalize` never needs the source's duration up front (`sampleCount` and `durationMs`
/// are derived from what was actually decoded and written, not from asset metadata that may be
/// approximate or absent).
///
/// The decode loop blocks its thread until the file is done, so it runs on `decodeQueue`, a dedicated
/// dispatch queue, never on Swift's small cooperative thread pool or on the caller's actor.
public struct AVAudioNormalizer: AudioNormalizing {
    private static let targetSampleRate: Double = 16_000
    private static let targetChannelCount: AVAudioChannelCount = 1

    static let decodeQueueLabel = "com.aarzamen.ichirp.audio.normalize"
    /// Concurrent, so each normalization gets its own dispatch thread; callers bound how many run at once
    /// (`FileTranscriptionPipeline` allows two). Blocking a dispatch thread does not starve Swift concurrency.
    private static let decodeQueue = DispatchQueue(label: decodeQueueLabel, qos: .utility, attributes: .concurrent)

    public init() {}

    /// `@concurrent`: always runs off the caller's actor, whatever the module's default isolation becomes.
    @concurrent
    public func normalize(sourceURL: URL, outputURL: URL) async throws -> NormalizedAudio {
        try Task.checkCancellation()
        let asset = AVURLAsset(url: sourceURL)

        let audioTracks: [AVAssetTrack]
        do {
            audioTracks = try await asset.loadTracks(withMediaType: .audio)
        } catch {
            throw AudioNormalizationError.readerFailed(error.localizedDescription)
        }
        guard let firstTrack = audioTracks.first else {
            throw AudioNormalizationError.noAudioTrack
        }

        // A hand-off, not sharing: after this line the track is only touched on the decode queue.
        nonisolated(unsafe) let track = firstTrack
        return try await Self.runOnDecodeQueue { isCancelled in
            try Self.decode(asset: asset, track: track, outputURL: outputURL, isCancelled: isCancelled)
        }
    }

    /// The blocking reader→writer loop. Runs on `decodeQueue` only (tests call it directly); `isCancelled` reports
    /// the awaiting task's cancellation and is checked once per decoded buffer.
    static func decode(
        asset: AVURLAsset,
        track: AVAssetTrack,
        outputURL: URL,
        isCancelled: () -> Bool
    ) throws -> NormalizedAudio {
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw AudioNormalizationError.readerFailed(error.localizedDescription)
        }

        let readerOutputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Self.targetSampleRate,
            AVNumberOfChannelsKey: Self.targetChannelCount,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let output = AVAssetReaderAudioMixOutput(audioTracks: [track], audioSettings: readerOutputSettings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw AudioNormalizationError.readerFailed("AVAssetReader cannot add the audio mix output")
        }
        reader.add(output)

        // File-storage settings for the 16 kHz mono Float32 WAV: no "non-interleaved" key here,
        // that's a processing-buffer concept controlled by `interleaved:` below, not a WAV
        // on-disk setting.
        let fileSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Self.targetSampleRate,
            AVNumberOfChannelsKey: Self.targetChannelCount,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
        ]

        let file: AVAudioFile
        do {
            file = try AVAudioFile(
                forWriting: outputURL,
                settings: fileSettings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
        } catch {
            throw AudioNormalizationError.readerFailed(
                "Could not open output file: \(error.localizedDescription)"
            )
        }

        guard reader.startReading() else {
            throw AudioNormalizationError.readerFailed(
                reader.error?.localizedDescription ?? "AVAssetReader could not start reading"
            )
        }

        var sampleCount = 0
        while let sampleBuffer = output.copyNextSampleBuffer() {
            if isCancelled() {
                reader.cancelReading()
                try? FileManager.default.removeItem(at: outputURL)
                throw CancellationError()
            }
            guard let pcmBuffer = Self.pcmBuffer(from: sampleBuffer, format: file.processingFormat) else {
                continue
            }
            do {
                try file.write(from: pcmBuffer)
            } catch {
                reader.cancelReading()
                throw AudioNormalizationError.readerFailed(
                    "Could not write decoded audio: \(error.localizedDescription)"
                )
            }
            sampleCount += Int(pcmBuffer.frameLength)
        }

        if reader.status == .failed {
            throw AudioNormalizationError.readerFailed(
                reader.error?.localizedDescription ?? "AVAssetReader failed while reading"
            )
        }

        let durationMs = Int((Double(sampleCount) / Self.targetSampleRate * 1_000).rounded())
        return NormalizedAudio(url: outputURL, durationMs: durationMs, sampleCount: sampleCount)
    }

    /// Runs blocking `work` on `decodeQueue` and returns its result. `work` receives a check that turns true once the
    /// awaiting task is cancelled (dispatch threads have no current task, so `Task.isCancelled` would stay false).
    static func runOnDecodeQueue<T: Sendable>(
        _ work: @escaping @Sendable (_ isCancelled: @escaping @Sendable () -> Bool) throws -> T
    ) async throws -> T {
        let cancelled = CancellationFlag()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                decodeQueue.async {
                    continuation.resume(with: Result { try work { cancelled.isSet } })
                }
            }
        } onCancel: {
            cancelled.set()
        }
    }

    /// `@concurrent`: always runs off the caller's actor, whatever the module's default isolation becomes.
    @concurrent
    public func durationMs(of sourceURL: URL) async throws -> Int {
        let asset = AVURLAsset(url: sourceURL)
        let duration: CMTime
        do {
            duration = try await asset.load(.duration)
        } catch {
            throw AudioNormalizationError.readerFailed(error.localizedDescription)
        }
        guard duration.isNumeric else { return 0 }
        return Int((CMTimeGetSeconds(duration) * 1_000).rounded())
    }

    /// Copies one decoded `CMSampleBuffer` (already 16 kHz mono Float32 PCM, per
    /// `readerOutputSettings`) into a fresh `AVAudioPCMBuffer` matching `format`, ready for
    /// `AVAudioFile.write(from:)`.
    private static func pcmBuffer(from sampleBuffer: CMSampleBuffer, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frameCount > 0,
            let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
            let destination = pcmBuffer.floatChannelData?[0]
        else {
            return nil
        }
        pcmBuffer.frameLength = frameCount

        var audioBufferList = AudioBufferList()
        var blockBuffer: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: &audioBufferList,
            bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr, let sourceData = audioBufferList.mBuffers.mData else { return nil }

        let byteCount = min(
            Int(audioBufferList.mBuffers.mDataByteSize),
            Int(frameCount) * MemoryLayout<Float>.size
        )
        _ = destination.withMemoryRebound(to: UInt8.self, capacity: byteCount) { destinationBytes in
            memcpy(destinationBytes, sourceData, byteCount)
        }
        return pcmBuffer
    }
}

/// A one-way flag set from a task's cancellation handler and read from a dispatch thread.
private final class CancellationFlag: Sendable {
    private let state = Mutex(false)

    var isSet: Bool { state.withLock { $0 } }

    func set() {
        state.withLock { $0 = true }
    }
}
