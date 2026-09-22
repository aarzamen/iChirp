import AVFoundation
import ChirpCore
import CoreMedia
import XCTest

@testable import ChirpAudio

final class AVAudioNormalizerTests: XCTestCase {
    private var tmpDir: URL!
    private var clipMovURL: URL!

    override func setUp() async throws {
        try await super.setUp()
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AVAudioNormalizerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        clipMovURL = try await MovieFixture.makeVideoPlusAudioClip(inDirectory: tmpDir)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmpDir)
        tmpDir = nil
        clipMovURL = nil
        try await super.tearDown()
    }

    private func fixtureURL(_ name: String, extension ext: String) throws -> URL {
        guard
            let url = Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures")
                ?? Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: ext)
        else {
            XCTFail("Missing fixture \(name).\(ext) in test bundle resources")
            throw XCTSkip("Fixture not found")
        }
        return url
    }

    private func outputURL(_ name: String) -> URL {
        tmpDir.appendingPathComponent(name).appendingPathExtension("wav")
    }

    private func assertNormalizedFormat(_ url: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        let file16k = try AVAudioFile(forReading: url)
        let format = file16k.processingFormat
        XCTAssertEqual(format.sampleRate, 16_000, file: file, line: line)
        XCTAssertEqual(format.channelCount, 1, file: file, line: line)
        XCTAssertEqual(format.commonFormat, .pcmFormatFloat32, file: file, line: line)
    }

    // MARK: - Fixture round trips

    func testNormalizesStereo44kM4AToMonoFloat16k() async throws {
        let source = try fixtureURL("tone-44k-stereo", extension: "m4a")
        let sourceDurationSeconds = try await CMTimeGetSeconds(AVURLAsset(url: source).load(.duration))
        let output = outputURL("tone-44k-stereo")

        let normalizer = AVAudioNormalizer()
        let result = try await normalizer.normalize(sourceURL: source, outputURL: output)

        try assertNormalizedFormat(result.url)
        XCTAssertEqual(result.url, output)

        let expectedSampleCount = sourceDurationSeconds * 16_000
        let tolerance = expectedSampleCount * 0.01
        XCTAssertEqual(Double(result.sampleCount), expectedSampleCount, accuracy: max(tolerance, 1))

        let expectedDurationMs = Int((sourceDurationSeconds * 1_000).rounded())
        XCTAssertEqual(result.durationMs, expectedDurationMs, accuracy: max(Int(sourceDurationSeconds * 10), 1))
    }

    func testNormalizesMono22kAIFFToMonoFloat16k() async throws {
        let source = try fixtureURL("speech-22k", extension: "aiff")
        let sourceDurationSeconds = try await CMTimeGetSeconds(AVURLAsset(url: source).load(.duration))
        let output = outputURL("speech-22k")

        let normalizer = AVAudioNormalizer()
        let result = try await normalizer.normalize(sourceURL: source, outputURL: output)

        try assertNormalizedFormat(result.url)

        let expectedSampleCount = sourceDurationSeconds * 16_000
        let tolerance = expectedSampleCount * 0.01
        XCTAssertEqual(Double(result.sampleCount), expectedSampleCount, accuracy: max(tolerance, 1))
    }

    func testNormalizesVideoPlusAudioMovByExtractingAudioTrack() async throws {
        let sourceDurationSeconds = try await CMTimeGetSeconds(AVURLAsset(url: clipMovURL).load(.duration))
        let output = outputURL("clip")

        let normalizer = AVAudioNormalizer()
        let result = try await normalizer.normalize(sourceURL: clipMovURL, outputURL: output)

        try assertNormalizedFormat(result.url)

        let expectedSampleCount = sourceDurationSeconds * 16_000
        let tolerance = expectedSampleCount * 0.01
        XCTAssertEqual(Double(result.sampleCount), expectedSampleCount, accuracy: max(tolerance, 1))
    }

    // MARK: - Errors

    func testNonAudioFileRenamedM4AThrows() async throws {
        let bogus = tmpDir.appendingPathComponent("not-audio.m4a")
        try Data("this is plainly not an audio file".utf8).write(to: bogus)

        let normalizer = AVAudioNormalizer()
        do {
            _ = try await normalizer.normalize(sourceURL: bogus, outputURL: outputURL("not-audio"))
            XCTFail("Expected normalize(sourceURL:outputURL:) to throw for a non-audio file")
        } catch {
            // Any error is acceptable: AVFoundation may fail to load tracks (surfaced as
            // .readerFailed) or return zero tracks (surfaced as .noAudioTrack).
        }
    }

    // MARK: - durationMs(of:)

    func testDurationMsOfMatchesAssetDuration() async throws {
        let source = try fixtureURL("speech-22k", extension: "aiff")
        let expected = try await CMTimeGetSeconds(AVURLAsset(url: source).load(.duration)) * 1_000

        let normalizer = AVAudioNormalizer()
        let durationMs = try await normalizer.durationMs(of: source)

        XCTAssertEqual(Double(durationMs), expected, accuracy: max(expected * 0.01, 1))
    }

    // MARK: - Cancellation

    /// End to end through `normalize`: a task cancelled before or while it runs throws `CancellationError` and
    /// leaves no WAV. Depending on timing the cancel is seen before loading or inside the loop; the next test pins
    /// the mid-file branch deterministically.
    func testCancellationStopsReaderAndRemovesPartialOutput() async throws {
        let source = try ToneFixture.makeLongTone(duration: 35, inDirectory: tmpDir)
        let output = outputURL("cancelled")
        let normalizer = AVAudioNormalizer()

        let task = Task {
            try await normalizer.normalize(sourceURL: source, outputURL: output)
        }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected normalize(sourceURL:outputURL:) to throw after the task was cancelled")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: output.path),
            "A cancelled normalize() must not leave a partial output WAV behind")
    }

    /// Drives the decode loop directly with a cancellation check that turns true after a few buffers, so the
    /// mid-file branch (stop the reader, delete the partial WAV, throw `CancellationError`) runs every time.
    func testDecodeLoopCancelledMidFileStopsAndRemovesPartialOutput() async throws {
        let source = try ToneFixture.makeLongTone(duration: 35, inDirectory: tmpDir)
        let output = outputURL("cancelled-mid-file")
        let asset = AVURLAsset(url: source)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let track = try XCTUnwrap(tracks.first)
        var checks = 0

        XCTAssertThrowsError(
            try AVAudioNormalizer.decode(asset: asset, track: track, outputURL: output) {
                checks += 1
                return checks > 3
            }
        ) { error in
            XCTAssertTrue(error is CancellationError, "got \(error)")
        }

        XCTAssertEqual(checks, 4, "three buffers were decoded before the cancel was seen")
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path), "the partial WAV is deleted")
    }

    // MARK: - Where the blocking decode runs

    /// The reader→writer loop blocks its thread for as long as the file takes to decode, so it runs on the
    /// normalizer's own dispatch queue, never on Swift's small cooperative pool or the caller's actor.
    func testBlockingWorkRunsOnTheDecodeQueue() async throws {
        let label = try await AVAudioNormalizer.runOnDecodeQueue { _ in
            String(cString: __dispatch_queue_get_label(nil))
        }
        XCTAssertEqual(label, AVAudioNormalizer.decodeQueueLabel)
    }

    @MainActor
    func testBlockingWorkCalledFromTheMainActorRunsOffTheMainThread() async throws {
        let ranOnMainThread = try await AVAudioNormalizer.runOnDecodeQueue { _ in Thread.isMainThread }
        XCTAssertFalse(ranOnMainThread)
    }

    /// Cancelling the awaiting task reaches the blocking work through its `isCancelled` check.
    func testBlockingWorkSeesTheCallersCancellation() async throws {
        let task = Task {
            try await AVAudioNormalizer.runOnDecodeQueue { isCancelled in
                let deadline = Date().addingTimeInterval(10)
                while !isCancelled(), Date() < deadline {
                    usleep(1_000)
                }
                return isCancelled()
            }
        }
        task.cancel()

        let sawCancellation = try await task.value
        XCTAssertTrue(sawCancellation)
    }
}

// MARK: - Long tone fixture (cancellation test)

/// Synthesizes a long mono sine tone straight to a WAV file with `AVAudioFile`, writing in small
/// chunks. Only used by the cancellation test, which needs an input with enough decode work
/// (many `CMSampleBuffer`s) that a cancelled `Task` reliably gets caught mid-loop rather than
/// completing before cancellation is ever observed. Never committed to disk.
private enum ToneFixture {
    enum FixtureError: Error {
        case couldNotCreateBuffer
    }

    static func makeLongTone(
        duration: Double,
        frequency: Double = 440,
        sampleRate: Double = 16_000,
        inDirectory directory: URL
    ) throws -> URL {
        let url = directory.appendingPathComponent("long-tone-\(UUID().uuidString).wav")
        let fileSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(
            forWriting: url, settings: fileSettings, commonFormat: .pcmFormatFloat32, interleaved: false)

        guard
            let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)
        else {
            throw FixtureError.couldNotCreateBuffer
        }

        let chunkFrameCount = 4_096
        var framesRemaining = Int((duration * sampleRate).rounded())
        var frameOffset = 0
        while framesRemaining > 0 {
            let framesToWrite = min(chunkFrameCount, framesRemaining)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(framesToWrite)),
                let channelData = buffer.floatChannelData
            else {
                throw FixtureError.couldNotCreateBuffer
            }
            buffer.frameLength = AVAudioFrameCount(framesToWrite)
            for frame in 0..<framesToWrite {
                let phase = 2.0 * Double.pi * frequency * Double(frameOffset + frame) / sampleRate
                channelData[0][frame] = Float(sin(phase)) * 0.2
            }
            try file.write(from: buffer)
            framesRemaining -= framesToWrite
            frameOffset += framesToWrite
        }

        return url
    }
}

// MARK: - clip.mov fixture

/// Builds small, synthetic AVFoundation fixtures at test time. `clip.mov` is never committed —
/// only `speech-22k.aiff` and `tone-44k-stereo.m4a` (both made once via `say`/`afconvert`, see
/// this target's README) live on disk in `Fixtures/`.
/// Internal (not private) so `AudioTrackSelectionTests` can build its two-audio-track movie with the same helpers.
enum MovieFixture {
    enum FixtureError: Error {
        case writerFailed(String)
        case couldNotBuildSampleBuffer
    }

    /// Writes a 1 second `.mov` with one video track (a single 64x64 frame) and one audio
    /// track (a 1 second 44.1 kHz mono sine tone), so `AVAudioNormalizer` has to pick the audio
    /// track out of a container that also carries video.
    static func makeVideoPlusAudioClip(inDirectory directory: URL) async throws -> URL {
        let url = directory.appendingPathComponent("clip.mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 64,
            AVVideoHeightKey: 64,
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = false
        let pixelBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: 64,
            kCVPixelBufferHeightKey as String: 64,
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: pixelBufferAttributes
        )
        guard writer.canAdd(videoInput) else {
            throw FixtureError.writerFailed("cannot add video input")
        }
        writer.add(videoInput)

        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        audioInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(audioInput) else {
            throw FixtureError.writerFailed("cannot add audio input")
        }
        writer.add(audioInput)

        guard writer.startWriting() else {
            throw FixtureError.writerFailed(writer.error?.localizedDescription ?? "startWriting failed")
        }
        writer.startSession(atSourceTime: .zero)

        try appendVideoFrame(to: adaptor, input: videoInput)
        videoInput.markAsFinished()

        let audioSampleBuffer = try makeSineWaveSampleBuffer(
            frequency: 440, sampleRate: 44_100, duration: 1.0, presentationTime: .zero)
        try appendAudio(audioSampleBuffer, to: audioInput)
        audioInput.markAsFinished()

        await withCheckedContinuation { continuation in
            writer.finishWriting {
                continuation.resume()
            }
        }

        guard writer.status == .completed else {
            throw FixtureError.writerFailed(
                writer.error?.localizedDescription ?? "finishWriting did not complete")
        }
        return url
    }

    private static func appendVideoFrame(
        to adaptor: AVAssetWriterInputPixelBufferAdaptor,
        input: AVAssetWriterInput
    ) throws {
        var pixelBufferOut: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32ARGB, nil, &pixelBufferOut)
        guard status == kCVReturnSuccess, let pixelBuffer = pixelBufferOut else {
            throw FixtureError.couldNotBuildSampleBuffer
        }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        if let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) {
            memset(baseAddress, 0x40, CVPixelBufferGetDataSize(pixelBuffer))
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

        var waited = 0
        while !input.isReadyForMoreMediaData, waited < 1_000 {
            usleep(1_000)
            waited += 1
        }
        guard adaptor.append(pixelBuffer, withPresentationTime: .zero) else {
            throw FixtureError.couldNotBuildSampleBuffer
        }
    }

    static func appendAudio(_ sampleBuffer: CMSampleBuffer, to input: AVAssetWriterInput) throws {
        var waited = 0
        while !input.isReadyForMoreMediaData, waited < 1_000 {
            usleep(1_000)
            waited += 1
        }
        guard input.append(sampleBuffer) else {
            throw FixtureError.couldNotBuildSampleBuffer
        }
    }

    /// A mono Float32 PCM `CMSampleBuffer` holding `duration` seconds of a sine tone.
    static func makeSineWaveSampleBuffer(
        frequency: Double,
        sampleRate: Double,
        duration: Double,
        presentationTime: CMTime,
        amplitude: Float = 0.2
    ) throws -> CMSampleBuffer {
        let frameCount = Int(sampleRate * duration)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)),
            let channelData = buffer.floatChannelData
        else {
            throw FixtureError.couldNotBuildSampleBuffer
        }
        buffer.frameLength = AVAudioFrameCount(frameCount)
        for frame in 0..<frameCount {
            let phase = 2.0 * Double.pi * frequency * Double(frame) / sampleRate
            channelData[0][frame] = Float(sin(phase)) * amplitude
        }

        var asbd = format.streamDescription.pointee
        var formatDescription: CMAudioFormatDescription?
        var status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDescription
        )
        guard status == noErr, let formatDescription else {
            throw FixtureError.couldNotBuildSampleBuffer
        }

        let byteCount = frameCount * MemoryLayout<Float>.size
        var blockBuffer: CMBlockBuffer?
        status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: byteCount,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == kCMBlockBufferNoErr, let blockBuffer else {
            throw FixtureError.couldNotBuildSampleBuffer
        }

        status = CMBlockBufferReplaceDataBytes(
            with: channelData[0], blockBuffer: blockBuffer, offsetIntoDestination: 0, dataLength: byteCount)
        guard status == kCMBlockBufferNoErr else {
            throw FixtureError.couldNotBuildSampleBuffer
        }

        var sampleBuffer: CMSampleBuffer?
        status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: CMItemCount(frameCount),
            presentationTimeStamp: presentationTime,
            packetDescriptions: nil,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sampleBuffer else {
            throw FixtureError.couldNotBuildSampleBuffer
        }
        return sampleBuffer
    }
}
