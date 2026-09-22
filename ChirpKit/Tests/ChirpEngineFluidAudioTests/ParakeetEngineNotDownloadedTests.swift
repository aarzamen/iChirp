import ChirpCore
import XCTest

@testable import ChirpEngineFluidAudio

/// With an empty models root nothing may be downloaded implicitly: status reports `.notDownloaded` and every
/// inference entry point throws `.modelNotDownloaded`, leaving the directory untouched.
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

    private func assertModelNotDownloaded(
        _ operation: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line
    ) async {
        do {
            try await operation()
            XCTFail("Expected SpeechEngineError.modelNotDownloaded", file: file, line: line)
        } catch let error as SpeechEngineError {
            guard case .modelNotDownloaded(let name) = error else {
                return XCTFail("Expected .modelNotDownloaded, got \(error)", file: file, line: line)
            }
            XCTAssertFalse(name.isEmpty, file: file, line: line)
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

        await assertModelNotDownloaded {
            _ = try await engine.transcribe(fileAt: fixture, options: SpeechTranscriptionOptions(), progress: { _ in })
        }
        await assertModelNotDownloaded { try await engine.prepare() }
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
        await assertModelNotDownloaded { _ = try await diarizer.diarize(fileAt: fixture) }
        await assertModelNotDownloaded { try await diarizer.prepare() }
        XCTAssertEqual(try contents(of: root), [], "diarize must never download models silently")
    }

    func testDeleteAssetsOnAnEmptyRootIsANoOp() async throws {
        let root = try makeEmptyModelsRoot()
        try await ParakeetEngine(variant: .v3, modelsRoot: root).deleteAssets()
        try await FluidAudioDiarizer(modelsRoot: root).deleteAssets()
        XCTAssertEqual(try contents(of: root), [])
    }
}
