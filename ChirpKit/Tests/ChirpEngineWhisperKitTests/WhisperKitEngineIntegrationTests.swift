import ChirpCore
import Foundation
import XCTest

@testable import ChirpEngineWhisperKit

/// The real WhisperKit on a synthetic `say` recording. Opt-in with `CHIRP_WHISPER_TESTS=1`, because it downloads the
/// model (base: about 150 MB; `CHIRP_WHISPER_VARIANT=large-v3-turbo`: about 650 MB). The models are kept in
/// `~/Library/Caches/iChirpTests/WhisperKit` (or `CHIRP_WHISPER_MODELS_DIR`) so a re-run does not download again.
final class WhisperKitEngineIntegrationTests: XCTestCase {
    func testTranscribesASyntheticRecordingWithMonotonicWordTimings() async throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(
            environment["CHIRP_WHISPER_TESTS"] == "1", "Set CHIRP_WHISPER_TESTS=1 to run the real WhisperKit model.")
        #if os(macOS)
        let variant = environment["CHIRP_WHISPER_VARIANT"].flatMap(WhisperKitVariant.init(rawValue:)) ?? .base
        let models =
            environment["CHIRP_WHISPER_MODELS_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("iChirpTests/WhisperKit", isDirectory: true)
        let engine = WhisperKitEngine(variant: variant, modelsDirectory: models)
        let status = await engine.assetStatus()
        if status == .notDownloaded {
            try await engine.downloadAssets { _ in }
        }
        let wav = try Self.makeSayRecording("The quick brown fox jumps over the lazy dog.")
        defer { try? FileManager.default.removeItem(at: wav.deletingLastPathComponent()) }

        try await engine.prepare()
        let progress = LockedValues()
        let result = try await engine.transcribe(fileAt: wav, options: .init(), progress: { progress.append($0) })
        // Review M1: real progress (the share of the file decoded) before the final 1, never a fixed value.
        XCTAssertEqual(progress.all.last, 1)
        XCTAssertTrue(progress.all.contains { $0 > 0 && $0 < 1 }, "\(progress.all)")
        XCTAssertEqual(progress.all, progress.all.sorted(), "never decreases")
        let lowered = result.text.lowercased()
        for word in ["quick", "brown", "fox", "lazy", "dog"] {
            XCTAssertTrue(lowered.contains(word), "\(word) missing from \(result.text)")
        }
        XCTAssertEqual(result.engineID, WhisperKitEngine.engineID)
        XCTAssertEqual(result.engineVariant, variant.rawValue)
        XCTAssertFalse(result.words.isEmpty)
        zip(result.words, result.words.dropFirst()).forEach { XCTAssertLessThanOrEqual($0.startMs, $1.startMs) }
        await engine.unloadModels()
        #else
        throw XCTSkip("The synthetic recording is made with macOS `say`.")
        #endif
    }

    #if os(macOS)
    static func makeSayRecording(_ text: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
            "whisperkit-say-\(UUID().uuidString)", isDirectory: true)
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
