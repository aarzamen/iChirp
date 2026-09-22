import AVFoundation
import ChirpCore
import XCTest

@testable import ChirpAudio

/// M3 Step 2: the meeting recorder through the real `SharedMicrophoneStream` on a fake engine. Synthetic constant
/// buffers only (48 kHz, like the iPhone's microphone).
final class MeetingRecorderTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingRecorderTests-\(UUID().uuidString)", isDirectory: true)
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
        let recorder: MeetingRecorder

        init() {
            session = AudioSessionController(platform: platform)
            stream = SharedMicrophoneStream(engine: engine, session: session)
            recorder = MeetingRecorder(stream: stream, session: session)
        }
    }

    private var outputURL: URL { directory.appendingPathComponent(MeetingSessionFiles.audio) }

    private func collect(_ updates: AsyncStream<CaptureUpdate>) -> Task<[CaptureUpdate], Never> {
        Task {
            var all: [CaptureUpdate] = []
            for await update in updates { all.append(update) }
            return all
        }
    }

    private func readSamples(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
    }

    func testWritesSixteenKilohertzMonoSixteenBitCAFWithEveryStreamedSample() async throws {
        let h = Harness()
        let updates = collect(try await h.recorder.start(recordingTo: outputURL))
        for _ in 0..<12 { XCTAssertTrue(h.engine.deliver(TestBuffers.constant(frames: 4_000))) }  // 1 s at 48 kHz
        let recorded = try await h.recorder.stop()

        let file = try AVAudioFile(forReading: recorded.url)
        XCTAssertEqual(file.fileFormat.sampleRate, 16_000)
        XCTAssertEqual(file.fileFormat.channelCount, 1)
        XCTAssertEqual(file.fileFormat.settings[AVLinearPCMBitDepthKey] as? Int, 16)
        XCTAssertEqual(file.fileFormat.settings[AVLinearPCMIsFloatKey] as? Bool, false)
        XCTAssertEqual(recorded.url.pathExtension, "caf")
        XCTAssertEqual(Int(file.length), recorded.sampleCount)
        XCTAssertEqual(Double(recorded.sampleCount), 16_000, accuracy: 16_000 * 0.01)

        let all = await updates.value
        let streamed = all.reduce(into: 0) { count, update in
            if case .samples(let samples) = update { count += samples.count }
        }
        XCTAssertEqual(streamed, recorded.sampleCount, "the live samples are exactly what the file holds")
        XCTAssertEqual(h.stream.diagnostics.subscriberCount, 0, "stop releases the microphone")
    }

    func testPauseWritesNothingAndMuteWritesSilenceWhileTheClockRuns() async throws {
        let h = Harness()
        _ = try await h.recorder.start(recordingTo: outputURL)
        h.engine.deliver(TestBuffers.constant(frames: 24_000))  // 0.5 s spoken
        await h.recorder.setPaused(true)
        h.engine.deliver(TestBuffers.constant(frames: 24_000))  // dropped
        await h.recorder.setPaused(false)
        await h.recorder.setMuted(true)
        h.engine.deliver(TestBuffers.constant(frames: 24_000))  // 0.5 s of silence
        await h.recorder.setMuted(false)
        h.engine.deliver(TestBuffers.constant(frames: 24_000))  // 0.5 s spoken
        let recorded = try await h.recorder.stop()

        XCTAssertEqual(Double(recorded.sampleCount), 24_000, accuracy: 240, "paused audio is not in the file")
        let samples = try readSamples(recorded.url)
        let spokenLevel = samples[4_000..<7_000].map(abs).max() ?? 0
        XCTAssertGreaterThan(spokenLevel, 0.2)
        let mutedPeak = samples[10_000..<14_000].map(abs).max() ?? 1
        XCTAssertEqual(mutedPeak, 0, accuracy: 0.0001, "muted time is recorded as silence")
        let lastPeak = samples[20_000..<23_000].map(abs).max() ?? 0
        XCTAssertGreaterThan(lastPeak, 0.2)
    }

    func testStopKeepsEvenAVeryShortRecording() async throws {
        let h = Harness()
        _ = try await h.recorder.start(recordingTo: outputURL)
        h.engine.deliver(TestBuffers.constant(frames: 4_800))  // 0.1 s
        let recorded = try await h.recorder.stop()
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path), "the recorder never deletes audio")
        XCTAssertEqual(Double(recorded.sampleCount), 1_600, accuracy: 100)
    }

    func testCancelStopsTheMicrophoneAndKeepsTheFile() async throws {
        let h = Harness()
        let updates = collect(try await h.recorder.start(recordingTo: outputURL))
        h.engine.deliver(TestBuffers.constant(frames: 48_000))
        await h.recorder.cancel()
        _ = await updates.value
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path), "only the coordinator deletes")
        XCTAssertFalse(h.engine.isRunning)
        do {
            _ = try await h.recorder.stop()
            XCTFail("nothing is recording after cancel")
        } catch {
            XCTAssertEqual(error as? AudioCaptureError, .notRecording)
        }
    }

    func testAnExistingRecordingIsNeverOverwritten() async throws {
        try Data("keep".utf8).write(to: outputURL)
        let h = Harness()
        do {
            _ = try await h.recorder.start(recordingTo: outputURL)
            XCTFail("expected startFailed")
        } catch {
            guard case .startFailed = error as? AudioCaptureError else {
                return XCTFail("unexpected \(error)")
            }
        }
        XCTAssertEqual(try String(contentsOf: outputURL, encoding: .utf8), "keep")
    }

    func testInterruptionIsReportedAndRecordingContinuesIntoTheSameFileAfterResume() async throws {
        let h = Harness()
        let updates = collect(try await h.recorder.start(recordingTo: outputURL))
        h.engine.deliver(TestBuffers.constant(frames: 24_000))
        h.platform.emit(.interruptionBegan)
        h.platform.emit(.interruptionEnded(shouldResume: false))
        await h.stream.drain()
        try await h.recorder.resume()
        h.engine.deliver(TestBuffers.constant(frames: 24_000))
        let recorded = try await h.recorder.stop()

        XCTAssertEqual(Double(recorded.sampleCount), 16_000, accuracy: 160, "both halves, one file")
        let events = await updates.value.compactMap { update -> CaptureEvent? in
            if case .event(let event) = update { event } else { nil }
        }
        XCTAssertEqual(events, [.interrupted, .waitingForResume, .resumed])
    }

    /// The format decision (M3 Step 1) inside the package: a CAF that was never closed stays readable to its last
    /// written buffer. The writer object is abandoned without `close()`, the way a killed process leaves it; the file
    /// is read through a second handle while the first is still open.
    func testAnUnclosedMeetingFileIsReadableUpToTheLastWrittenBuffer() throws {
        let writer = try MeetingAudioWriter(url: outputURL, extractChannelZero: false)
        for _ in 0..<10 { writer.process(TestBuffers.constant(frames: 4_800)) }  // 1 s at 48 kHz
        let file = try AVAudioFile(forReading: outputURL)
        XCTAssertEqual(Double(file.length), 16_000, accuracy: 400)
        _ = writer.close()
    }
}
