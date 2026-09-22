import ChirpCore
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
}
