import AVFoundation
import ChirpCore
import XCTest

@testable import ChirpEngineFluidAudio

/// M3: Silero voice activity behind `VoiceActivityDetecting`.
///
/// The status and never-download checks always run (against an empty temporary models root). The real-model check
/// runs only with `CHIRP_MODEL_TESTS=1` and uses the model already in FluidAudio's default cache (it downloads about
/// 2 MB when missing):
///
/// ```bash
/// CHIRP_MODEL_TESTS=1 swift test --package-path ChirpKit --filter FluidAudioVoiceActivityTests
/// ```
final class FluidAudioVoiceActivityTests: XCTestCase {
    func testDescriptorIsOnDeviceVoiceActivityAndAnUncachedModelGivesNoStreamWithoutDownloading() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vad-\(UUID().uuidString)/Models", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let vad = FluidAudioVoiceActivity(modelsRoot: root)
        XCTAssertEqual(vad.descriptor.kind, .voiceActivity)
        XCTAssertEqual(vad.descriptor.locality, .onDevice)
        XCTAssertEqual(vad.windowSize, 4_096)
        XCTAssertEqual(vad.modelDirectory.lastPathComponent, "silero-vad")
        let status = await vad.assetStatus()
        XCTAssertEqual(status, .notDownloaded)
        let stream = await vad.makeStream(config: VoiceActivityConfig())
        XCTAssertNil(stream, "no model on disk: fixed chunks, and nothing is downloaded")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testRealSileroFindsSpeechStartAndEndInTheTwoVoiceFixture() async throws {
        guard ProcessInfo.processInfo.environment["CHIRP_MODEL_TESTS"] == "1" else {
            throw XCTSkip("Set CHIRP_MODEL_TESTS=1 to run the real Silero VAD test.")
        }
        let vad = FluidAudioVoiceActivity()
        if case .notDownloaded = await vad.assetStatus() {
            try await vad.downloadAssets { _ in }
        }
        let stream = try await XCTUnwrapAsync(vad)
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "two-voices-16k", withExtension: "wav", subdirectory: "Fixtures"))
        let file = try AVAudioFile(forReading: url)
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let samples = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
        // Trailing silence so the last speech end is reported.
        let padded = samples + [Float](repeating: 0, count: 16_000)
        var events: [VoiceActivityEvent] = []
        var index = 0
        while index + vad.windowSize <= padded.count {
            if let event = try await stream.process(Array(padded[index..<(index + vad.windowSize)])) {
                events.append(event)
            }
            index += vad.windowSize
        }
        XCTAssertEqual(events.first, .speechStart)
        let ends = events.compactMap { event -> Int? in
            if case .speechEnd(let sample) = event { sample } else { nil }
        }
        XCTAssertFalse(ends.isEmpty, "speech ends are reported: \(events)")
        XCTAssertTrue(ends.allSatisfy { $0 > 0 && $0 <= padded.count })
    }

    private func XCTUnwrapAsync(_ vad: FluidAudioVoiceActivity) async throws -> any VoiceActivityStream {
        let stream = await vad.makeStream(config: VoiceActivityConfig())
        return try XCTUnwrap(stream, "the model is on disk, so a stream exists")
    }
}
