import ChirpCore
import FluidAudio
import XCTest

@testable import ChirpEngineFluidAudio

/// With an empty models root nothing may be downloaded implicitly: status reports `.notDownloaded` and every
/// inference entry point throws `.modelNotDownloaded(<engine id>)`, leaving the directory untouched.
final class ParakeetEngineNotDownloadedTests: XCTestCase {
    private func makeEmptyModelsRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ichirp-empty-models-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func fixtureURL() throws -> URL {
        try XCTUnwrap(Bundle.module.url(forResource: "two-voices-16k", withExtension: "wav", subdirectory: "Fixtures"))
    }

    /// The contract (`spec/contracts/speech-engine-plugin-v1.md`) says the error carries the engine id, not the
    /// display name.
    private func assertModelNotDownloaded(
        engineID: String, _ operation: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line
    ) async {
        do {
            try await operation()
            XCTFail("Expected SpeechEngineError.modelNotDownloaded", file: file, line: line)
        } catch let error as SpeechEngineError {
            guard case .modelNotDownloaded(let carried) = error else {
                return XCTFail("Expected .modelNotDownloaded, got \(error)", file: file, line: line)
            }
            XCTAssertEqual(carried, engineID, file: file, line: line)
        } catch {
            XCTFail("Expected SpeechEngineError, got \(error)", file: file, line: line)
        }
    }

    private func contents(of root: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: root.path)
    }

    func testAssetStatusIsNotDownloadedForAnEmptyModelsRoot() async throws {
        let root = try makeEmptyModelsRoot()
        for variant in ParakeetVariant.allCases {
            let status = await ParakeetEngine(variant: variant, modelsRoot: root).assetStatus()
            XCTAssertEqual(status, .notDownloaded, "\(variant)")
        }
        XCTAssertEqual(try contents(of: root), [])
    }

    func testTranscribeThrowsModelNotDownloadedAndDownloadsNothing() async throws {
        let root = try makeEmptyModelsRoot()
        let fixture = try fixtureURL()
        let engine = ParakeetEngine(variant: .v3, modelsRoot: root)

        await assertModelNotDownloaded(engineID: ParakeetEngine.engineID) {
            _ = try await engine.transcribe(fileAt: fixture, options: SpeechTranscriptionOptions(), progress: { _ in })
        }
        await assertModelNotDownloaded(engineID: ParakeetEngine.engineID) { try await engine.prepare() }
        XCTAssertEqual(try contents(of: root), [], "transcribe must never download models silently")
        let status = await engine.assetStatus()
        XCTAssertEqual(status, .notDownloaded)
    }

    func testDiarizerThrowsModelNotDownloadedAndDownloadsNothing() async throws {
        let root = try makeEmptyModelsRoot()
        let fixture = try fixtureURL()
        let diarizer = FluidAudioDiarizer(modelsRoot: root)

        let status = await diarizer.assetStatus()
        XCTAssertEqual(status, .notDownloaded)
        let diarizerID = FluidAudioDiarizer.engineDescriptor.id
        await assertModelNotDownloaded(engineID: diarizerID) { _ = try await diarizer.diarize(fileAt: fixture) }
        await assertModelNotDownloaded(engineID: diarizerID) { try await diarizer.prepare() }
        XCTAssertEqual(try contents(of: root), [], "diarize must never download models silently")
    }

    func testDeleteAssetsOnAnEmptyRootIsANoOp() async throws {
        let root = try makeEmptyModelsRoot()
        try await ParakeetEngine(variant: .v3, modelsRoot: root).deleteAssets()
        try await FluidAudioDiarizer(modelsRoot: root).deleteAssets()
        XCTAssertEqual(try contents(of: root), [])
    }

    // MARK: - Partial downloads (ready means complete)

    /// A cache shaped like a finished `AsrModels.download` of v3: every compiled bundle with its root
    /// `coremldata.bin`, plus the vocabulary JSON, which FluidAudio writes last. Names come from FluidAudio directly.
    private func writeCompleteParakeetV3Cache(in root: URL) throws -> URL {
        let directory = root.appendingPathComponent(Repo.parakeetV3.folderName, isDirectory: true)
        for bundle in ModelNames.ASR.requiredModelsV3(precision: .int8) {
            let bundleURL = directory.appendingPathComponent(bundle)
            let weights = bundleURL.appendingPathComponent("weights")
            try FileManager.default.createDirectory(at: weights, withIntermediateDirectories: true)
            try Data("model".utf8).write(to: bundleURL.appendingPathComponent("coremldata.bin"))
            try Data("weights".utf8).write(to: weights.appendingPathComponent("weight.bin"))
        }
        try Data("{}".utf8).write(to: directory.appendingPathComponent(ModelNames.ASR.vocabularyFile))
        return directory
    }

    private func writeCompleteDiarizerCache(in root: URL) throws -> URL {
        let directory = root.appendingPathComponent(Repo.diarizer.folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for file in ModelNames.OfflineDiarizer.requiredModels {
            let url = directory.appendingPathComponent(file)
            if file.hasSuffix(".mlmodelc") {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                try Data("model".utf8).write(to: url.appendingPathComponent("coremldata.bin"))
            } else {
                try Data("{}".utf8).write(to: url)
            }
        }
        let marker = directory.appendingPathComponent(".fluidaudio-revision")
        try Data((Repo.diarizer.revision + "\n").utf8).write(to: marker)
        return directory
    }

    private func parakeetStatus(_ root: URL) async -> ModelAssetStatus {
        await ParakeetEngine(variant: .v3, modelsRoot: root).assetStatus()
    }

    func testACompleteParakeetCacheIsReadyAndNeedsNoRepair() async throws {
        let root = try makeEmptyModelsRoot()
        _ = try writeCompleteParakeetV3Cache(in: root)

        guard case .ready = await parakeetStatus(root) else {
            return XCTFail("a complete cache must read as ready")
        }
        XCTAssertFalse(FluidAudioModelLocations.parakeetNeedsRepair(in: root, variant: .v3))
    }

    /// FluidAudio's own `AsrModels.modelsExist` checks only that each bundle folder exists (plus the vocabulary),
    /// so it calls this cache complete and `AsrModels.download` would stop early without repairing it.
    func testABundleMissingItsCoreMLDataReadsAsNotDownloadedAndNeedsRepair() async throws {
        let root = try makeEmptyModelsRoot()
        let directory = try writeCompleteParakeetV3Cache(in: root)
        try FileManager.default.removeItem(
            at: directory.appendingPathComponent(ModelNames.ASR.encoderFile).appendingPathComponent("coremldata.bin"))

        XCTAssertTrue(AsrModels.modelsExist(at: directory, version: .v3), "FluidAudio's looser check still passes")
        let status = await parakeetStatus(root)
        XCTAssertEqual(status, .notDownloaded)
        XCTAssertTrue(FluidAudioModelLocations.parakeetNeedsRepair(in: root, variant: .v3))
    }

    /// FluidAudio streams each file into `<name>.partial` and renames it when complete; a leftover one means the
    /// download was interrupted inside that bundle.
    func testAnInterruptedFileDownloadReadsAsNotDownloadedAndNeedsRepair() async throws {
        let root = try makeEmptyModelsRoot()
        let directory = try writeCompleteParakeetV3Cache(in: root)
        let weights = directory.appendingPathComponent(ModelNames.ASR.encoderFile).appendingPathComponent("weights")
        try FileManager.default.removeItem(at: weights.appendingPathComponent("weight.bin"))
        try Data("half".utf8).write(to: weights.appendingPathComponent("weight.bin.partial"))

        let status = await parakeetStatus(root)
        XCTAssertEqual(status, .notDownloaded)
        XCTAssertTrue(FluidAudioModelLocations.parakeetNeedsRepair(in: root, variant: .v3))
    }

    /// Without the vocabulary (written last) FluidAudio's own check fails too, so `AsrModels.download` runs in full
    /// and no separate repair is needed.
    func testAMissingVocabularyReadsAsNotDownloaded() async throws {
        let root = try makeEmptyModelsRoot()
        let directory = try writeCompleteParakeetV3Cache(in: root)
        try FileManager.default.removeItem(at: directory.appendingPathComponent(ModelNames.ASR.vocabularyFile))

        let status = await parakeetStatus(root)
        XCTAssertEqual(status, .notDownloaded)
        XCTAssertFalse(FluidAudioModelLocations.parakeetNeedsRepair(in: root, variant: .v3))
    }

    func testAPartialDiarizerCacheReadsAsNotDownloaded() async throws {
        let root = try makeEmptyModelsRoot()
        let directory = try writeCompleteDiarizerCache(in: root)
        guard case .ready = await FluidAudioDiarizer(modelsRoot: root).assetStatus() else {
            return XCTFail("a complete diarizer cache must read as ready")
        }

        let bundle = directory.appendingPathComponent(ModelNames.OfflineDiarizer.embeddingFile)
        try Data("half".utf8).write(to: bundle.appendingPathComponent("weight.bin.partial"))
        let withPartial = await FluidAudioDiarizer(modelsRoot: root).assetStatus()
        XCTAssertEqual(withPartial, .notDownloaded)

        try FileManager.default.removeItem(at: bundle.appendingPathComponent("weight.bin.partial"))
        try FileManager.default.removeItem(at: bundle.appendingPathComponent("coremldata.bin"))
        let withoutCoreMLData = await FluidAudioDiarizer(modelsRoot: root).assetStatus()
        XCTAssertEqual(withoutCoreMLData, .notDownloaded)
    }
}
