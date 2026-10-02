import AVFoundation
import ChirpCore
import FluidAudio
import XCTest

@testable import ChirpEngineFluidAudio

/// M3: Silero voice activity behind `VoiceActivityDetecting`.
///
/// The status and never-download checks always run (against temporary models roots). The real-model check runs only
/// with `CHIRP_MODEL_TESTS=1` and uses the model already in FluidAudio's default cache (it downloads about 2 MB when
/// missing):
///
/// ```bash
/// CHIRP_MODEL_TESTS=1 swift test --package-path ChirpKit --filter FluidAudioVoiceActivityTests
/// ```
final class FluidAudioVoiceActivityTests: XCTestCase {
    private struct SyntheticLoadFailure: Error {}

    private func scratchModelsRoot() throws -> URL {
        let root = try makeScratchDirectory("vad").appendingPathComponent("Models", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// The Silero bundle folder as an interrupted download leaves it: no root `coremldata.bin`, a `.partial` weight.
    private func writePartialBundle(in root: URL) throws -> URL {
        let bundle = FluidAudioModelLocations.voiceActivityDirectory(in: root)
            .appendingPathComponent(ModelNames.VAD.sileroVadFile, isDirectory: true)
        let weights = bundle.appendingPathComponent("weights", isDirectory: true)
        try FileManager.default.createDirectory(at: weights, withIntermediateDirectories: true)
        try Data(repeating: 7, count: 512).write(to: weights.appendingPathComponent("weight.bin.partial"))
        return bundle
    }

    /// A bundle with every file the strict check wants but nothing CoreML can load (a damaged cache).
    private func writeUnloadableCompleteBundle(in root: URL) throws -> URL {
        let bundle = FluidAudioModelLocations.voiceActivityDirectory(in: root)
            .appendingPathComponent(ModelNames.VAD.sileroVadFile, isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try Data("not a model".utf8).write(to: bundle.appendingPathComponent("coremldata.bin"))
        return bundle
    }

    private func isExcludedFromBackup(_ url: URL) throws -> Bool {
        try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup ?? false
    }

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

    // MARK: - Review R3-3: the shared lifecycle — strict "ready", never a silent download

    /// An interrupted download leaves the bundle folder without `coremldata.bin`. It is not Ready, and starting a
    /// meeting gets fixed chunks instead of FluidAudio purging the folder and downloading it again.
    func testAPartialCacheIsNotReadyAndMakeStreamNeitherPurgesNorDownloads() async throws {
        continueAfterFailure = false  // before the fix, the next step would purge and re-download over the network
        let root = try scratchModelsRoot()
        let bundle = try writePartialBundle(in: root)
        let vad = FluidAudioVoiceActivity(modelsRoot: root)
        let status = await vad.assetStatus()
        XCTAssertEqual(status, .notDownloaded, "a partial cache must not read Ready")

        let stream = await vad.makeStream(config: VoiceActivityConfig())
        XCTAssertNil(stream)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: bundle.appendingPathComponent("weights/weight.bin.partial").path),
            "the partial download is kept for the next Download tap to resume")
    }

    /// A cache that looks complete but cannot load gives fixed chunks; the folder is kept (never purged) and is
    /// excluded from backups, as every downloaded model folder must be (also for folders from before this fix).
    func testADamagedCacheGivesNoStreamKeepsTheFolderAndExcludesItFromBackup() async throws {
        let root = try scratchModelsRoot()
        let bundle = try writeUnloadableCompleteBundle(in: root)
        let vad = FluidAudioVoiceActivity(modelsRoot: root)
        guard case .ready = await vad.assetStatus() else { return XCTFail("every required file is present") }
        let stream = await vad.makeStream(config: VoiceActivityConfig())
        XCTAssertNil(stream, "CoreML cannot load it: fixed chunks")
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundle.appendingPathComponent("coremldata.bin").path))
        XCTAssertTrue(try isExcludedFromBackup(vad.modelDirectory))
    }

    /// Download on a cache that is already complete fetches nothing and marks the folder excluded from backup.
    func testDownloadExcludesTheFolderFromBackup() async throws {
        let root = try scratchModelsRoot()
        _ = try writeUnloadableCompleteBundle(in: root)
        let vad = FluidAudioVoiceActivity(modelsRoot: root)
        XCTAssertFalse(try isExcludedFromBackup(vad.modelDirectory))
        try await vad.downloadAssets { _ in }
        XCTAssertTrue(try isExcludedFromBackup(vad.modelDirectory))
        try await vad.deleteAssets()
        let status = await vad.assetStatus()
        XCTAssertEqual(status, .notDownloaded)
        XCTAssertFalse(FileManager.default.fileExists(atPath: vad.modelDirectory.path))
    }

    /// Two meeting starts at once share one load (the old code checked `manager == nil` before an `await` and could
    /// load twice), and neither touches the network.
    func testConcurrentStreamsShareOneLocalLoadAndNeverDownload() async throws {
        let root = try scratchModelsRoot()
        let presentChecks = LockedLog<Int>()
        let loads = LockedLog<Int>()
        let downloads = LockedLog<Int>()
        let latch = Latch()
        let hooks = ModelAssetLifecycle<VadManager>.Hooks(
            engineID: FluidAudioVoiceActivity.engineID,
            displayName: "Silero voice activity",
            modelsPresent: {
                presentChecks.append(1)
                return true
            },
            bytesOnDisk: { 2_000_000 },
            download: { _ in downloads.append(1) },
            load: {
                loads.append(1)
                await latch.wait()
                throw SyntheticLoadFailure()
            },
            remove: {}
        )
        let vad = FluidAudioVoiceActivity(
            modelsRoot: root, hooks: hooks, network: .testing(path: .unusable(reason: "off")))
        async let first = vad.makeStream(config: VoiceActivityConfig())
        async let second = vad.makeStream(config: VoiceActivityConfig())
        // Each caller checks the files once, right before it starts or joins the load (no suspension in between).
        await waitUntil { presentChecks.values.count >= 2 }
        await latch.open()
        let streams = await [first, second]
        XCTAssertTrue(streams.allSatisfy { $0 == nil }, "the load failed: fixed chunks for both")
        XCTAssertEqual(loads.values.count, 1, "one load for both callers")
        XCTAssertEqual(downloads.values.count, 0, "using the engine never downloads")
    }

    func testRealSileroFindsSpeechStartAndEndInTheTwoVoiceFixture() async throws {
        guard ProcessInfo.processInfo.environment["CHIRP_MODEL_TESTS"] == "1" else {
            throw XCTSkip("Set CHIRP_MODEL_TESTS=1 to run the real Silero VAD test.")
        }
        let vad = FluidAudioVoiceActivity()
        if case .notDownloaded = await vad.assetStatus() {
            try await vad.downloadAssets { _ in }
        }
        XCTAssertTrue(try isExcludedFromBackup(vad.modelDirectory))
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
