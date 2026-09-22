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
}

// MARK: - clip.mov fixture

/// Builds small, synthetic AVFoundation fixtures at test time. `clip.mov` is never committed —
/// only `speech-22k.aiff` and `tone-44k-stereo.m4a` (both made once via `say`/`afconvert`, see
/// this target's README) live on disk in `Fixtures/`.
private enum MovieFixture {
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

    private static func appendAudio(_ sampleBuffer: CMSampleBuffer, to input: AVAssetWriterInput) throws {
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
    private static func makeSineWaveSampleBuffer(
        frequency: Double,
        sampleRate: Double,
        duration: Double,
        presentationTime: CMTime
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
            channelData[0][frame] = Float(sin(phase)) * 0.2
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
