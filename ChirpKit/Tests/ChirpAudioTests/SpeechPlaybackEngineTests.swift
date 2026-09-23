import AVFoundation
import ChirpCore
import XCTest

@testable import ChirpAudio

/// Plan 020: speech playback shares M2's audio session. Recording pre-empts it (the reading pauses and never resumes
/// by itself), playback cannot start while recording, and temporary audio is cleaned up.
@MainActor
final class SpeechPlaybackEngineTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "voice-playback-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testBeginTakesThePlaybackSessionAndStopReleasesItAndDeletesTheFolder() throws {
        let platform = FakeAudioSessionPlatform()
        let session = AudioSessionController(platform: platform)
        let engine = SpeechPlaybackEngine(session: session, temporaryRoot: root)

        try engine.beginUtterance()
        XCTAssertEqual(session.activeUse, .playback)
        let folder = try XCTUnwrap(engine.currentTemporaryDirectory)
        XCTAssertTrue(folder.lastPathComponent.hasPrefix("speech-"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))

        engine.stop()
        XCTAssertNil(session.activeUse)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertEqual(
            platform.calls, [.configure(.playback), .setActive(true), .setActive(false)],
            "other apps are told they may resume")
    }

    func testPlaybackCannotBeginWhileRecording() throws {
        let session = AudioSessionController(platform: FakeAudioSessionPlatform())
        try session.activate(for: .recording)
        let engine = SpeechPlaybackEngine(session: session, temporaryRoot: root)

        XCTAssertThrowsError(try engine.beginUtterance()) { error in
            XCTAssertEqual(error as? AudioSessionController.SessionError, .recordingInProgress)
        }
        XCTAssertEqual(session.activeUse, .recording, "the dictation keeps the session")
        XCTAssertFalse(engine.isUtteranceActive)
    }

    func testRecordingPausesTheReadingAndItNeverResumesByItself() async throws {
        let session = AudioSessionController(platform: FakeAudioSessionPlatform())
        let engine = SpeechPlaybackEngine(session: session, temporaryRoot: root)
        var events: [SpeechPlaybackEvent] = []
        engine.onEvent = { events.append($0) }
        try engine.beginUtterance()

        try session.activate(for: .recording)  // a dictation or a meeting starts
        for _ in 0..<200 where events.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(events, [.interrupted])
        XCTAssertEqual(session.activeUse, .recording, "recording behavior is unchanged: it holds the session")

        XCTAssertThrowsError(try engine.resume(), "no playback while recording") { error in
            XCTAssertEqual(error as? AudioSessionController.SessionError, .recordingInProgress)
        }
        session.deactivate(for: .recording)  // the dictation ended
        try engine.resume()
        XCTAssertEqual(session.activeUse, .playback)
        engine.stop()
    }

    func testStopDoesNotReleaseASessionThatRecordingHolds() throws {
        let session = AudioSessionController(platform: FakeAudioSessionPlatform())
        let engine = SpeechPlaybackEngine(session: session, temporaryRoot: root)
        try engine.beginUtterance()
        try session.activate(for: .recording)
        engine.stop()
        XCTAssertEqual(session.activeUse, .recording)
    }

    func testStaleFoldersAreSweptWhenTheEngineIsMade() throws {
        let stale = root.appendingPathComponent("speech-left-by-a-killed-launch", isDirectory: true)
        let other = root.appendingPathComponent("export-keep-me", isDirectory: true)
        for folder in [stale, other] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        _ = SpeechPlaybackEngine(
            session: AudioSessionController(platform: FakeAudioSessionPlatform()), temporaryRoot: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path))

        let live = root.appendingPathComponent("speech-live", isDirectory: true)
        try FileManager.default.createDirectory(at: live, withIntermediateDirectories: true)
        XCTAssertEqual(SpeechPlaybackEngine.sweepStaleAudio(in: root, keeping: live), 0, "a live folder is kept")
    }

    func testAChunkPlaysToTheEndAndItsFileIsDeleted() async throws {
        let session = AudioSessionController(platform: FakeAudioSessionPlatform())
        let engine = SpeechPlaybackEngine(session: session, temporaryRoot: root)
        var events: [SpeechPlaybackEvent] = []
        engine.onEvent = { events.append($0) }
        try engine.beginUtterance()
        let folder = try XCTUnwrap(engine.currentTemporaryDirectory)
        do {
            try engine.enqueue(
                SynthesizedAudio(data: try Self.silentWAV(seconds: 0.15), format: .wav), index: 0, pauseAfterMs: 0,
                isFinal: true)
        } catch {
            engine.stop()
            throw XCTSkip("No audio output on this Mac: \(error.localizedDescription)")
        }
        XCTAssertEqual(events.first, .chunkStarted(0))
        for _ in 0..<400 where !events.contains(.finished) { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(events, [.chunkStarted(0), .finished])
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path), "temporary audio is gone")
        XCTAssertNil(session.activeUse)
    }

    /// A 16-bit mono 24 kHz WAV of silence (synthetic).
    static func silentWAV(seconds: Double) throws -> Data {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("silence-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1))
        let frames = AVAudioFrameCount(24_000 * seconds)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        do {
            let file = try AVAudioFile(
                forWriting: url,
                settings: [
                    AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 24_000, AVNumberOfChannelsKey: 1,
                    AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
                ])
            try file.write(from: buffer)
        }
        return try Data(contentsOf: url)
    }
}
