// Fresh implementation for iChirp (plan 022 Step 5): one voice message file from synthesized chunks. The reading side
// follows `SpeechPlaybackEngine` (each chunk is a file `AVAudioFile` reads, whatever the engine returned); the writing
// side is AVFoundation's AAC encoder through `AVAudioFile`.

import AVFoundation
import ChirpCore
import Foundation

public enum VoiceMessageWriterError: Error, Equatable, LocalizedError {
    case noAudio
    case unreadableChunk(Int)
    case encodingFailed(String)

    public var errorDescription: String? {
        switch self {
        case .noAudio: "There was no audio to save."
        case .unreadableChunk(let index): "Part \(index + 1) of the voice audio could not be read."
        case .encodingFailed(let reason): "The voice message could not be saved: \(reason)"
        }
    }
}

/// Writes speech chunks into one mono AAC `.m4a` (24 kHz, 48 kbit/s: speech, small enough to message). Chunks at any
/// rate or channel count are converted; the silence between chunks is written as real zero samples.
public struct VoiceMessageWriter: VoiceMessageWriting {
    public static let sampleRate: Double = 24_000
    public static let bitRate = 48_000

    public init() {}

    public func writeVoiceMessage(chunks: [URL], pausesAfterMs: [Int], to url: URL) async throws -> Int {
        try await Task.detached(priority: .userInitiated) {
            try Self.write(chunks: chunks, pausesAfterMs: pausesAfterMs, to: url)
        }.value
    }

    static func write(chunks: [URL], pausesAfterMs: [Int], to url: URL) throws -> Int {
        guard !chunks.isEmpty else { throw VoiceMessageWriterError.noAudio }
        guard
            let outputFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)
        else { throw VoiceMessageWriterError.encodingFailed("no output format") }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: bitRate,
        ]
        try? FileManager.default.removeItem(at: url)
        var written: AVAudioFramePosition = 0
        do {
            let output = try AVAudioFile(
                forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            defer { output.close() }
            for (index, chunk) in chunks.enumerated() {
                written += try append(chunk: chunk, index: index, to: output, format: outputFormat)
                let pause = index < pausesAfterMs.count ? pausesAfterMs[index] : 0
                written += try appendSilence(ms: pause, to: output, format: outputFormat)
            }
        } catch {
            try? FileManager.default.removeItem(at: url)
            if error is VoiceMessageWriterError { throw error }
            throw VoiceMessageWriterError.encodingFailed(error.localizedDescription)
        }
        guard written > 0 else {
            try? FileManager.default.removeItem(at: url)
            throw VoiceMessageWriterError.noAudio
        }
        return Int((Double(written) / sampleRate * 1_000).rounded())
    }

    /// Decodes one chunk and writes it converted to `format`. Returns the frames written.
    private static func append(
        chunk url: URL, index: Int, to output: AVAudioFile, format: AVAudioFormat
    ) throws -> AVAudioFramePosition {
        let input: AVAudioFile
        do {
            input = try AVAudioFile(forReading: url)
        } catch {
            throw VoiceMessageWriterError.unreadableChunk(index)
        }
        guard let converter = AVAudioConverter(from: input.processingFormat, to: format),
            let reader = ChunkReader(file: input)
        else { throw VoiceMessageWriterError.unreadableChunk(index) }
        let capacity =
            AVAudioFrameCount(
                (Double(ChunkReader.blockFrames) * format.sampleRate / input.processingFormat.sampleRate).rounded(.up))
            + 1_024
        var frames: AVAudioFramePosition = 0
        while true {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
                throw VoiceMessageWriterError.encodingFailed("no buffer")
            }
            var error: NSError?
            // The input block is `@Sendable`; it runs synchronously inside `convert`.
            let status = converter.convert(to: buffer, error: &error) { _, outStatus in
                if let next = reader.next() {
                    outStatus.pointee = .haveData
                    return next
                }
                outStatus.pointee = .endOfStream
                return nil
            }
            if status == .error {
                throw VoiceMessageWriterError.encodingFailed(error?.localizedDescription ?? "conversion failed")
            }
            if reader.failed { throw VoiceMessageWriterError.unreadableChunk(index) }
            if buffer.frameLength > 0 {
                try output.write(from: buffer)
                frames += AVAudioFramePosition(buffer.frameLength)
            }
            if status == .endOfStream || status == .inputRanDry { break }
        }
        return frames
    }

    private static func appendSilence(ms: Int, to output: AVAudioFile, format: AVAudioFormat) throws
        -> AVAudioFramePosition
    {
        let count = AVAudioFrameCount((Double(max(0, ms)) / 1_000 * format.sampleRate).rounded())
        guard count > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count) else { return 0 }
        buffer.frameLength = count
        if let channel = buffer.floatChannelData?[0] {
            channel.update(repeating: 0, count: Int(count))
        }
        try output.write(from: buffer)
        return AVAudioFramePosition(count)
    }
}

/// Hands one chunk's decoded audio to the converter block by block.
private final class ChunkReader: @unchecked Sendable {
    static let blockFrames: AVAudioFrameCount = 8_192

    private let file: AVAudioFile
    private let buffer: AVAudioPCMBuffer
    private var finished = false
    private(set) var failed = false

    init?(file: AVAudioFile) {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: Self.blockFrames) else {
            return nil
        }
        self.file = file
        self.buffer = buffer
    }

    func next() -> AVAudioPCMBuffer? {
        guard !finished else { return nil }
        do {
            try file.read(into: buffer, frameCount: Self.blockFrames)
        } catch {
            finished = true
            // Reading at the end of the file throws on some formats; only a read before the end is a failure.
            failed = file.framePosition < file.length
            return nil
        }
        guard buffer.frameLength > 0 else {
            finished = true
            return nil
        }
        return buffer
    }
}
