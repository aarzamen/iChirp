import ChirpCore
import Foundation
import XCTest

@testable import ChirpEngineAppleSpeech

/// The real `SpeechTranscriber` on a synthetic `say` recording. Opt-in (`CHIRP_APPLE_SPEECH_TESTS=1`) because it may
/// ask iOS/macOS to install the English speech model. It runs on a Mac with macOS 26 or an iPhone; the Simulator
/// has no `SpeechTranscriber` (`isAvailable` is false), so it is skipped there.
final class AppleSpeechEngineIntegrationTests: XCTestCase {
    func testTranscribesASyntheticRecordingWithMonotonicWordTimings() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["CHIRP_APPLE_SPEECH_TESTS"] == "1",
            "Set CHIRP_APPLE_SPEECH_TESTS=1 to run the real Apple Speech model.")
        let engine = AppleSpeechEngine(locale: Locale(identifier: "en_US"))
        if let reason = await engine.unavailableReason() {
            throw XCTSkip("Apple Speech is not available here (Simulator or unsupported device): \(reason)")
        }
        #if os(macOS)
        let wav = try Self.makeSayRecording("The quick brown fox jumps over the lazy dog.")
        defer { try? FileManager.default.removeItem(at: wav.deletingLastPathComponent()) }
        #else
        throw XCTSkip("The synthetic recording is made with macOS `say`.")
        #endif
        let status = await engine.assetStatus()
        if status == .notDownloaded {
            try await engine.downloadAssets { _ in }
        }
        try await engine.prepare()
        let result = try await engine.transcribe(fileAt: wav, options: .init(), progress: { _ in })
        let lowered = result.text.lowercased()
        for word in ["quick", "brown", "fox", "lazy", "dog"] {
            XCTAssertTrue(lowered.contains(word), "\(word) missing from \(result.text)")
        }
        XCTAssertEqual(result.engineID, AppleSpeechEngine.engineID)
        XCTAssertFalse(result.words.isEmpty)
        zip(result.words, result.words.dropFirst()).forEach { XCTAssertLessThanOrEqual($0.startMs, $1.startMs) }
    }

    #if os(macOS)
    /// 16 kHz 16-bit mono WAV from macOS `say` (synthetic, no PHI).
    static func makeSayRecording(_ text: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
            "apple-speech-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("say-16k.wav")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = ["-o", url.path, "--data-format=LEI16@16000", text]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw XCTSkip("`say` failed") }
        return url
    }
    #endif
}
