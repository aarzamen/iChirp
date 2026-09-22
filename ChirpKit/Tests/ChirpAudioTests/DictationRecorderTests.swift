import AVFoundation
import ChirpCore
import XCTest

@testable import ChirpAudio

/// M2 Step 2: the dictation recorder, fed through the real `SharedMicrophoneStream` on a fake engine. The audio is
/// the committed synthetic `say` fixture (`Fixtures/speech-22k.aiff`), cut into tap-sized buffers.
final class DictationRecorderTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DictationRecorderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private struct Harness {
        let platform = FakeAudioSessionPlatform()
        let engine = FakeMicrophoneEngine()
        let session: AudioSessionController
        let stream: SharedMicrophoneStream
        let recorder: DictationRecorder

        init(voiceProcessing: Bool = false) {
            session = AudioSessionController(platform: platform)
            stream = SharedMicrophoneStream(engine: engine, session: session)
            recorder = DictationRecorder(stream: stream, session: session, voiceProcessing: voiceProcessing)
        }
    }

    private var outputURL: URL { directory.appendingPathComponent("dictation.wav") }

    private func fixtureURL() throws -> URL {
        let url =
            Bundle.module.url(forResource: "speech-22k", withExtension: "aiff", subdirectory: "Fixtures")
            ?? Bundle.module.url(forResource: "Fixtures/speech-22k", withExtension: "aiff")
        return try XCTUnwrap(url, "missing Fixtures/speech-22k.aiff")
    }

    /// The fixture as tap-sized buffers in its own processing format (22.05 kHz mono Float32).
    private func fixtureBuffers(frames: AVAudioFrameCount = 4096) throws -> (buffers: [AVAudioPCMBuffer], length: Int) {
        let file = try AVAudioFile(forReading: try fixtureURL())
        var buffers: [AVAudioPCMBuffer] = []
        while file.framePosition < file.length {
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames))
            try file.read(into: buffer, frameCount: frames)
            if buffer.frameLength == 0 { break }
            buffers.append(buffer)
        }
        return (buffers, Int(file.length))
    }

    /// Collects every update until the stream ends.
    private func collect(_ updates: AsyncStream<CaptureUpdate>) -> Task<[CaptureUpdate], Never> {
        Task {
            var all: [CaptureUpdate] = []
            for await update in updates { all.append(update) }
            return all
        }
    }

    func testRecordsSayFixtureAsSixteenKilohertzMonoWithinOnePercentOfItsDuration() async throws {
        let h = Harness()
        let (buffers, sourceFrames) = try fixtureBuffers()
        let sourceSeconds = Double(sourceFrames) / 22_050

        let updates = collect(try await h.recorder.start(recordingTo: outputURL))
        for buffer in buffers { XCTAssertTrue(h.engine.deliver(buffer)) }
        let recorded = try await h.recorder.stop()

        let file = try AVAudioFile(forReading: recorded.url)
        XCTAssertEqual(file.fileFormat.sampleRate, 16_000)
        XCTAssertEqual(file.fileFormat.channelCount, 1)
        XCTAssertEqual(file.processingFormat.commonFormat, .pcmFormatFloat32)
        XCTAssertEqual(Int(file.length), recorded.sampleCount)
        let recordedSeconds = Double(recorded.sampleCount) / 16_000
        XCTAssertEqual(recordedSeconds, sourceSeconds, accuracy: sourceSeconds * 0.01)
        XCTAssertEqual(Double(recorded.durationMs) / 1000, recordedSeconds, accuracy: 0.001)

        // The live samples are exactly the audio written to the file, in order.
        let all = await updates.value
        let streamed = all.reduce(into: 0) { count, update in
            if case .samples(let samples) = update { count += samples.count }
        }
        XCTAssertEqual(streamed, recorded.sampleCount)
        XCTAssertTrue(all.contains { if case .level(let level) = $0 { level > 0 } else { false } })
        XCTAssertEqual(h.stream.diagnostics.subscriberCount, 0, "stop releases the microphone")
        XCTAssertNil(h.session.activeUse)
    }

    func testShorterThanPointThreeSecondsIsRejectedAndItsFileRemoved() async throws {
        let h = Harness()
        _ = try await h.recorder.start(recordingTo: outputURL)
        // 0.25 s at 48 kHz.
        h.engine.deliver(TestBuffers.constant(frames: 12_000))
        do {
            _ = try await h.recorder.stop()
            XCTFail("expected tooShort")
        } catch {
            XCTAssertEqual(error as? AudioCaptureError, .tooShort)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path))
    }

    func testCancelStopsTheMicrophoneAndDeletesTheFile() async throws {
        let h = Harness()
        let updates = collect(try await h.recorder.start(recordingTo: outputURL))
        h.engine.deliver(TestBuffers.constant(frames: 48_000))
        await h.recorder.cancel()
        _ = await updates.value
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path))
        XCTAssertFalse(h.engine.isRunning)
        do {
            _ = try await h.recorder.stop()
            XCTFail("nothing is recording after cancel")
        } catch {
            XCTAssertEqual(error as? AudioCaptureError, .notRecording)
        }
    }

    func testInterruptionIsReportedAndRecordingContinuesIntoTheSameFileAfterResume() async throws {
        let h = Harness()
        let updates = collect(try await h.recorder.start(recordingTo: outputURL))
        h.engine.deliver(TestBuffers.constant(frames: 24_000))  // 0.5 s
        h.platform.emit(.interruptionBegan)
        h.platform.emit(.interruptionEnded(shouldResume: false))
        await h.stream.drain()
        try await h.recorder.resume()
        h.engine.deliver(TestBuffers.constant(frames: 24_000))  // 0.5 s more
        let recorded = try await h.recorder.stop()

        XCTAssertEqual(recorded.sampleCount, 16_000, "both halves, one file")
        let events = await updates.value.compactMap { update -> CaptureEvent? in
            if case .event(let event) = update { event } else { nil }
        }
        XCTAssertEqual(events, [.interrupted, .waitingForResume, .resumed])
    }

    func testStereoInputIsDownmixedAndVoiceProcessingKeepsChannelZero() throws {
        let stereo = TestBuffers.constant(frames: 64, values: [0.5, 0.1])
        let mixed = try XCTUnwrap(microphoneCaptureMonoBuffer(from: stereo, extractVoiceProcessingChannelZero: false))
        XCTAssertEqual(mixed.format.channelCount, 1)
        XCTAssertEqual(mixed.floatChannelData![0][10], 0.3, accuracy: 0.0001)

        let channelZero = try XCTUnwrap(
            microphoneCaptureMonoBuffer(from: stereo, extractVoiceProcessingChannelZero: true))
        XCTAssertEqual(channelZero.format.channelCount, 1)
        XCTAssertEqual(channelZero.floatChannelData![0][10], 0.5, accuracy: 0.0001)
    }

    func testPhaseCancellingChannelsKeepTheLoudestChannelInsteadOfSilence() throws {
        let cancelling = TestBuffers.constant(frames: 64, values: [0.4, -0.4])
        let mixed = try XCTUnwrap(downmixChannelsToMono(from: cancelling))
        XCTAssertEqual(abs(mixed.floatChannelData![0][5]), 0.4, accuracy: 0.0001)
    }

    func testStartWhileRecordingIsRefused() async throws {
        let h = Harness()
        _ = try await h.recorder.start(recordingTo: outputURL)
        do {
            _ = try await h.recorder.start(recordingTo: directory.appendingPathComponent("second.wav"))
            XCTFail("expected alreadyRecording")
        } catch {
            XCTAssertEqual(error as? AudioCaptureError, .alreadyRecording)
        }
        await h.recorder.cancel()
    }
}
