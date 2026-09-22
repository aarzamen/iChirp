import ChirpCore
import XCTest

@testable import ChirpEngineFluidAudio

/// Real-model run: downloads Parakeet TDT v3 (~0.5 GB) and the offline diarizer from Hugging Face into
/// `~/Library/Caches/ichirp-test-models`, then transcribes and diarizes the two-voice fixture.
///
/// Skipped unless `CHIRP_MODEL_TESTS=1`:
///
/// ```bash
/// CHIRP_MODEL_TESTS=1 swift test --package-path ChirpKit --filter ParakeetEngineIntegrationTests
/// ```
///
/// The fixture is already 16 kHz mono 16-bit PCM, the `AudioNormalizing` output format, so it is passed directly.
final class ParakeetEngineIntegrationTests: XCTestCase {
    private func requireModelTests() throws {
        guard ProcessInfo.processInfo.environment["CHIRP_MODEL_TESTS"] == "1" else {
            throw XCTSkip("Set CHIRP_MODEL_TESTS=1 to run the real-model Parakeet and diarizer test.")
        }
    }

    private var modelsRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/ichirp-test-models", isDirectory: true)
    }

    private func fixtureURL() throws -> URL {
        try XCTUnwrap(Bundle.module.url(forResource: "two-voices-16k", withExtension: "wav", subdirectory: "Fixtures"))
    }

    private func isExcludedFromBackup(_ url: URL) throws -> Bool {
        try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup ?? false
    }

    func testV3TranscribesAndDiarizesTheTwoVoiceFixture() async throws {
        try requireModelTests()
        let fixture = try fixtureURL()
        let engine = ParakeetEngine(variant: .v3, modelsRoot: modelsRoot)

        let downloadStart = ContinuousClock.now
        let downloadFractions = FractionLog()
        try await engine.downloadAssets { downloadFractions.append($0) }
        print("[ParakeetEngineIntegrationTests] Parakeet v3 assets ready in \(ContinuousClock.now - downloadStart)")
        XCTAssertEqual(downloadFractions.values.last, 1)
        let fractions = downloadFractions.values
        XCTAssertEqual(fractions, fractions.sorted(), "download progress must be monotonic")
        guard case .ready(let bytes) = await engine.assetStatus() else {
            return XCTFail("Parakeet assets should be ready after downloadAssets")
        }
        print("[ParakeetEngineIntegrationTests] Parakeet v3 bytes on disk: \(bytes)")
        XCTAssertGreaterThan(bytes, 100_000_000)
        let parakeetDirectory = FluidAudioModelLocations.parakeetDirectory(in: modelsRoot, variant: .v3)
        XCTAssertTrue(try isExcludedFromBackup(parakeetDirectory))

        let prepareStart = ContinuousClock.now
        try await engine.prepare()
        try await engine.prepare()  // idempotent
        print("[ParakeetEngineIntegrationTests] prepare (load + compile) took \(ContinuousClock.now - prepareStart)")

        let transcribeStart = ContinuousClock.now
        let transcribeFractions = FractionLog()
        let result = try await engine.transcribe(
            fileAt: fixture, options: SpeechTranscriptionOptions(), progress: { transcribeFractions.append($0) })
        let transcribeElapsed = ContinuousClock.now - transcribeStart
        print("[ParakeetEngineIntegrationTests] transcript: \(result.text)")
        print(
            "[ParakeetEngineIntegrationTests] words: \(result.words.count), transcribe took \(transcribeElapsed), "
                + "language: \(result.language ?? "nil"), variant: \(result.engineVariant ?? "nil")")
        print(
            "[ParakeetEngineIntegrationTests] word timings: "
                + result.words.map { "\($0.word)@\($0.startMs)-\($0.endMs)" }.joined(separator: " "))

        let lowercased = result.text.lowercased()
        XCTAssertTrue(lowercased.contains("quick brown fox"), result.text)
        XCTAssertTrue(lowercased.contains("iphone"), result.text)
        XCTAssertGreaterThan(result.words.count, 10)
        XCTAssertEqual(result.engineID, "fluidaudio.parakeet-tdt")
        XCTAssertEqual(result.engineVariant, "v3")
        XCTAssertEqual(transcribeFractions.values.first, 0)
        XCTAssertEqual(transcribeFractions.values.last, 1)
        for (previous, next) in zip(result.words, result.words.dropFirst()) {
            XCTAssertLessThanOrEqual(previous.startMs, next.startMs, "word starts must not go backwards")
            XCTAssertLessThanOrEqual(previous.endMs, next.endMs, "word ends must not go backwards")
        }
        XCTAssertTrue(result.words.allSatisfy { $0.startMs <= $0.endMs })

        let diarizer = FluidAudioDiarizer(modelsRoot: modelsRoot)
        let diarizerDownloadStart = ContinuousClock.now
        try await diarizer.downloadAssets { _ in }
        guard case .ready(let diarizerBytes) = await diarizer.assetStatus() else {
            return XCTFail("Diarizer assets should be ready after downloadAssets")
        }
        print(
            "[ParakeetEngineIntegrationTests] diarizer assets ready in \(ContinuousClock.now - diarizerDownloadStart), "
                + "bytes on disk: \(diarizerBytes)")
        XCTAssertTrue(try isExcludedFromBackup(FluidAudioModelLocations.diarizerDirectory(in: modelsRoot)))

        let diarizeStart = ContinuousClock.now
        let diarization = try await diarizer.diarize(fileAt: fixture)
        print(
            "[ParakeetEngineIntegrationTests] speakers: \(diarization.speakers.count) "
                + "(\(diarization.speakers.map(\.label).joined(separator: ", "))), diarize took "
                + "\(ContinuousClock.now - diarizeStart)")
        print(
            "[ParakeetEngineIntegrationTests] segments: "
                + diarization.segments.map { "\($0.speakerId)@\($0.startMs)-\($0.endMs)" }.joined(separator: " "))
        XCTAssertGreaterThanOrEqual(diarization.speakers.count, 1)
        XCTAssertEqual(diarization.segments.first?.speakerId, "S1")
        XCTAssertEqual(diarization.segments.map(\.startMs), diarization.segments.map(\.startMs).sorted())
    }

    /// Two concurrent jobs on one engine with audio longer than one 15 s window, the case where both open
    /// FluidAudio's per-manager progress stream. Sharing one `AsrManager` traps in `AsyncStreamBuffer`.
    func testTwoConcurrentLongTranscriptionsOnOneEngine() async throws {
        try requireModelTests()
        let scratch = try makeScratchDirectory("ichirp-long")
        let long = try writeLoopedWAV(of: try fixtureURL(), times: 3, in: scratch)
        let engine = ParakeetEngine(variant: .v3, modelsRoot: modelsRoot)
        try await engine.downloadAssets { _ in }

        let start = ContinuousClock.now
        let logA = LockedLog<Double>()
        let logB = LockedLog<Double>()
        async let first = engine.transcribe(fileAt: long, options: SpeechTranscriptionOptions()) { logA.append($0) }
        async let second = engine.transcribe(fileAt: long, options: SpeechTranscriptionOptions()) { logB.append($0) }
        let results = try await [first, second]
        print("[ParakeetEngineIntegrationTests] two concurrent 16.5 s jobs took \(ContinuousClock.now - start)")

        for (result, log) in zip(results, [logA, logB]) {
            print(
                "[ParakeetEngineIntegrationTests] concurrent transcript (\(result.words.count) words): \(result.text)")
            print("[ParakeetEngineIntegrationTests] progress: \(log.values.map { String(format: "%.2f", $0) })")
            let lowercased = result.text.lowercased()
            XCTAssertTrue(lowercased.contains("quick brown fox"), result.text)
            XCTAssertTrue(lowercased.contains("iphone"), result.text)
            XCTAssertGreaterThan(result.words.count, 30)
            XCTAssertEqual(log.values.first, 0)
            XCTAssertEqual(log.values.last, 1)
            XCTAssertEqual(log.values, log.values.sorted())
        }
    }
}

private final class FractionLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Double] = []

    func append(_ value: Double) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }

    var values: [Double] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
