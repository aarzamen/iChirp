import ChirpCore
import Foundation
import XCTest

@testable import ChirpFeatures

/// Review R4-7: the benchmark's 16 kHz copies of the recordings it measures (a person's own file among them, possibly
/// clinical audio) live in `tmp/asr-benchmark-<uuid>/` only while a run needs them, even when iOS ends the app
/// mid-run.
final class ASRBenchmarkWorkSweepTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ASRBenchmarkWorkSweepTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func runner(normalizer: FakeNormalizer = FakeNormalizer()) -> ASRBenchmarkRunner {
        ASRBenchmarkRunner(
            scheduler: SpeechJobScheduler(), normalizer: normalizer, memory: { nil }, workDirectory: folder,
            sampleInterval: .milliseconds(1))
    }

    private func makeEntry(_ name: String, directory: Bool) throws -> URL {
        let url = folder.appendingPathComponent(name, isDirectory: directory)
        if directory {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try Data(repeating: 1, count: 16).write(to: url.appendingPathComponent("item-0.wav"))
        } else {
            try Data(repeating: 1, count: 16).write(to: url)
        }
        return url
    }

    func testAKilledRunsCopiesAreSweptAndNothingElse() throws {
        let leftover = try makeEntry("asr-benchmark-\(UUID().uuidString)", directory: true)
        let strangers = [
            try makeEntry("asr-benchmark-not-a-run", directory: true),
            try makeEntry("asr-benchmark-\(UUID().uuidString).wav", directory: false),
            try makeEntry("export-\(UUID().uuidString)", directory: true),
            try makeEntry("benchmark-imports", directory: true),
            try makeEntry("other.wav", directory: false),
        ]

        let removed = runner().removeLeftoverWork()

        XCTAssertEqual(removed, 1)
        XCTAssertFalse(fileExists(leftover), "the killed run's normalized copies are gone")
        for stranger in strangers {
            XCTAssertTrue(fileExists(stranger), "never touched: \(stranger.lastPathComponent)")
        }
    }

    func testARunningRunsFolderSurvivesASweep() async throws {
        let normalizer = FakeNormalizer()
        let entered = Signal()
        await normalizer.parkNormalizations { entered.fire() }
        let audio = try makeEntry("synthetic.m4a", directory: false)
        let runner = runner(normalizer: normalizer)
        let engine = ASRBenchmarkEngine(
            key: SpeechEngineVariantKey(engineID: SpeechEngineCapabilityRegistry.parakeetEngineID, variant: "v3"),
            name: "Parakeet", engine: FakeSpeech())
        let item = ASRBenchmarkItem(id: "a", title: "Your file 1", audioURL: audio, referenceText: nil)

        let run = Task { try await runner.run(engines: [engine], items: [item]) }
        await entered.wait()
        let working = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .filter { $0.hasPrefix("asr-benchmark-") }
        XCTAssertEqual(working.count, 1)

        XCTAssertEqual(runner.removeLeftoverWork(), 0, "a run in progress keeps its copies")
        XCTAssertTrue(fileExists(folder.appendingPathComponent(working[0])))

        await normalizer.releaseParked()
        let results = try await run.value
        XCTAssertEqual(results.count, 1)
        XCTAssertFalse(fileExists(folder.appendingPathComponent(working[0])), "the run removes its own copies")
    }

    func testANewRunSweepsWhatAKilledRunLeft() async throws {
        let leftover = try makeEntry("asr-benchmark-\(UUID().uuidString)", directory: true)
        let audio = try makeEntry("synthetic.m4a", directory: false)
        let engine = ASRBenchmarkEngine(
            key: SpeechEngineVariantKey(engineID: SpeechEngineCapabilityRegistry.parakeetEngineID, variant: "v3"),
            name: "Parakeet", engine: FakeSpeech())

        _ = try await runner().run(
            engines: [engine], items: [ASRBenchmarkItem(id: "a", title: "x", audioURL: audio, referenceText: nil)])

        XCTAssertFalse(fileExists(leftover))
    }

    @MainActor
    func testTheScreensLaunchSweepAlsoRemovesAKilledRunsCopies() throws {
        let leftover = try makeEntry("asr-benchmark-\(UUID().uuidString)", directory: true)
        let key = SpeechEngineVariantKey(engineID: SpeechEngineCapabilityRegistry.parakeetEngineID, variant: "v3")
        let model = ASRBenchmarkViewModel(
            router: SpeechEngineRouter(engines: [.init(key: key, engine: FakeSpeech())]), runner: runner(),
            store: ASRBenchmarkStore(fileURL: folder.appendingPathComponent("runs.json")), referenceFolder: nil,
            importFolder: folder.appendingPathComponent("imports"), device: "Test", appBuild: "1.0 (1)")

        model.removeLeftoverImports()

        XCTAssertFalse(fileExists(leftover))
    }
}
