import ChirpCore
import ChirpText
import XCTest

@testable import ChirpFeatures

/// M7 Step 6: the benchmark runner, its export and store, and the screen's view model, with fake engines.
@MainActor
final class ASRBenchmarkTests: XCTestCase {
    /// A fake engine that can be unloaded (counts unloads) and reports a fixed text.
    actor UnloadingSpeech: SpeechEngine, SpeechEngineUnloading {
        nonisolated let descriptor: EngineDescriptor
        private let text: String
        private let status: ModelAssetStatus
        private(set) var unloads = 0
        private(set) var prepares = 0
        private(set) var transcribes = 0
        private(set) var downloads = 0

        init(
            id: String, text: String, status: ModelAssetStatus = .ready(bytesOnDisk: 1),
            locality: EngineLocality = .onDevice
        ) {
            self.descriptor = EngineDescriptor(
                id: id, kind: .speech, provider: "Test", displayName: id, locality: locality, license: "MIT")
            self.text = text
            self.status = status
        }

        func unloadModels() async { unloads += 1 }
        func assetStatus() async -> ModelAssetStatus { status }
        func downloadAssets(progress: @escaping @Sendable (Double) -> Void) async throws { downloads += 1 }
        func deleteAssets() async throws {}
        func prepare() async throws {
            prepares += 1
            try await Task.sleep(for: .milliseconds(5))
        }
        func transcribe(
            fileAt url: URL, options: SpeechTranscriptionOptions, progress: @escaping @Sendable (Double) -> Void
        ) async throws -> SpeechResult {
            transcribes += 1
            try await Task.sleep(for: .milliseconds(5))
            return SpeechResult(text: text, words: [], language: "en", engineID: descriptor.id, engineVariant: nil)
        }
    }

    private var folder: URL!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ASRBenchmarkTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func runner(memory: @escaping @Sendable () -> UInt64? = { 100 }) -> ASRBenchmarkRunner {
        ASRBenchmarkRunner(
            scheduler: SpeechJobScheduler(), normalizer: FakeNormalizer(), memory: memory, workDirectory: folder,
            sampleInterval: .milliseconds(1))
    }

    /// A synthetic "recording" on disk (the fake normalizer reads its bytes, never decodes them).
    private func item(_ id: String, reference: String?) -> ASRBenchmarkItem {
        let url = folder.appendingPathComponent("\(id).m4a")
        try? Data(repeating: 7, count: 64).write(to: url)
        return ASRBenchmarkItem(id: id, title: id, audioURL: url, referenceText: reference)
    }

    func testEachEngineRunsEveryItemWithWERRealTimeFactorAndOneLoad() async throws {
        let good = UnloadingSpeech(id: "fake.good", text: "The quick brown fox.")
        let poor = UnloadingSpeech(id: "fake.poor", text: "the quick crown")
        let results = try await runner().run(
            engines: [
                ASRBenchmarkEngine(key: .init(engineID: "fake.good"), name: "Good", engine: good),
                ASRBenchmarkEngine(key: .init(engineID: "fake.poor"), name: "Poor", engine: poor),
            ],
            items: [item("a", reference: "the quick brown fox"), item("b", reference: "the quick brown fox")])

        XCTAssertEqual(results.map(\.engineName), ["Good", "Good", "Poor", "Poor"])
        XCTAssertEqual(results.map { $0.wordErrorRate?.rate ?? -1 }, [0, 0, 0.5, 0.5])
        XCTAssertNotNil(results[0].loadMs)
        XCTAssertNil(results[1].loadMs, "the load is measured once per engine")
        for result in results {
            XCTAssertNil(result.error)
            XCTAssertEqual(result.audioSeconds, Double(FakeNormalizer.durationMs) / 1_000)
            XCTAssertNotNil(result.realTimeFactor)
            XCTAssertEqual(result.peakMemoryBytes, 100)
        }
        let (prepares, unloads) = (await good.prepares, await good.unloads)
        XCTAssertEqual(prepares, 1)
        XCTAssertEqual(unloads, 2, "unloaded before and after its turn")
    }

    func testAnEngineWithoutItsModelIsReportedNeverDownloaded() async throws {
        let missing = UnloadingSpeech(id: "fake.missing", text: "x", status: .notDownloaded)
        let results = try await runner().run(
            engines: [ASRBenchmarkEngine(key: .init(engineID: "fake.missing"), name: "Missing", engine: missing)],
            items: [item("a", reference: "x")])
        XCTAssertEqual(results.first?.error, "Model not downloaded. Download it in Settings → Speech engines.")
        let (downloads, transcribes) = (await missing.downloads, await missing.transcribes)
        XCTAssertEqual(downloads, 0)
        XCTAssertEqual(transcribes, 0)
    }

    func testAPersonsOwnFileIsTreatedAsClinicalAndItsTextIsNotKept() async throws {
        let cloud = UnloadingSpeech(id: "fake.cloud", text: "secret", locality: .cloud)
        let local = UnloadingSpeech(id: "fake.local", text: "secret words")
        let results = try await runner().run(
            engines: [
                ASRBenchmarkEngine(key: .init(engineID: "fake.cloud"), name: "Cloud", engine: cloud),
                ASRBenchmarkEngine(key: .init(engineID: "fake.local"), name: "Local", engine: local),
            ],
            items: [item("mine", reference: nil)])
        XCTAssertEqual(results[0].error, "Privacy routing does not allow Cloud for this recording.")
        let cloudCalls = await cloud.transcribes
        XCTAssertEqual(cloudCalls, 0)
        XCTAssertNil(results[1].error)
        XCTAssertNil(results[1].hypothesis, "a person's own recording keeps numbers only")
        XCTAssertNil(results[1].wordErrorRate)
        XCTAssertNotNil(results[1].realTimeFactor)
    }

    func testPeakMemoryIsTheHighestSampleDuringTheRun() async throws {
        let samples = LockedLog<UInt64>()
        let engine = UnloadingSpeech(id: "fake.a", text: "hello")
        let results = try await runner(memory: {
            let next = UInt64(samples.values.count % 5) * 10 + 50
            samples.append(next)
            return next
        }).run(
            engines: [ASRBenchmarkEngine(key: .init(engineID: "fake.a"), name: "A", engine: engine)],
            items: [item("a", reference: "hello")])
        XCTAssertEqual(results.first?.peakMemoryBytes, samples.values.max())
    }

    func testSummariesUseCorpusWERAndTotalTime() {
        let wer = WordErrorRate(substitutions: 1, deletions: 0, insertions: 0, referenceWords: 4)
        let run = ASRBenchmarkRun(
            startedAt: Date(timeIntervalSince1970: 0), device: "Mac", appBuild: "1.0 (1)",
            results: [
                ASRBenchmarkResult(
                    engineKey: "e", engineName: "E", itemID: "a", itemTitle: "a", audioSeconds: 10,
                    wordErrorRate: wer, realTimeFactor: 0.1, transcribeMs: 1_000, loadMs: 500, peakMemoryBytes: 10),
                ASRBenchmarkResult(
                    engineKey: "e", engineName: "E", itemID: "b", itemTitle: "b", audioSeconds: 30,
                    wordErrorRate: WordErrorRate(substitutions: 0, deletions: 0, insertions: 0, referenceWords: 16),
                    realTimeFactor: 0.1, transcribeMs: 3_000, peakMemoryBytes: 30),
            ])
        let summary = run.summaries.first
        XCTAssertEqual(summary?.wordErrorRate?.rate ?? -1, 0.05, accuracy: 1e-9)
        XCTAssertEqual(summary?.realTimeFactor ?? -1, 0.1, accuracy: 1e-9)
        XCTAssertEqual(summary?.loadMs, 500)
        XCTAssertEqual(summary?.peakMemoryBytes, 30)
    }

    func testCSVHasOneQuotedRowPerResultAndJSONIsVersioned() throws {
        let run = ASRBenchmarkRun(
            startedAt: Date(timeIntervalSince1970: 0), device: "iPhone, test", appBuild: "1.0 (1)",
            results: [
                ASRBenchmarkResult(
                    engineKey: "argmax.whisperkit:base", engineName: "Whisper Base", itemID: "a", itemTitle: "a",
                    audioSeconds: 2,
                    wordErrorRate: WordErrorRate(substitutions: 1, deletions: 0, insertions: 0, referenceWords: 4),
                    realTimeFactor: 0.25, transcribeMs: 500, loadMs: 120, peakMemoryBytes: 1_048_576 * 300,
                    error: "said \"no\"")
            ])
        let lines = ASRBenchmarkExport.csv([run]).split(separator: "\n")
        XCTAssertEqual(String(lines[0]), ASRBenchmarkExport.csvHeader)
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[1].contains("\"iPhone, test\""))
        XCTAssertTrue(lines[1].contains(",0.2500,1,0,0,4,0.2500,500,120,300.0,\"said \"\"no\"\"\""), String(lines[1]))
        let json = try JSONSerialization.jsonObject(with: ASRBenchmarkExport.json([run])) as? [String: Any]
        XCTAssertEqual(json?["format"] as? String, "ichirp.asr-benchmark/v1")
        XCTAssertEqual((json?["runs"] as? [Any])?.count, 1)
    }

    func testTheStoreKeepsTheNewestRunsAndDropsTextWithoutAReference() async throws {
        let store = ASRBenchmarkStore(fileURL: folder.appendingPathComponent("runs.json"), limit: 2)
        for index in 0..<3 {
            try await store.append(
                ASRBenchmarkRun(
                    startedAt: Date(timeIntervalSince1970: Double(index)), device: "d\(index)", appBuild: "b",
                    results: [
                        ASRBenchmarkResult(
                            engineKey: "e", engineName: "E", itemID: "mine", itemTitle: "mine.m4a", audioSeconds: 1,
                            hypothesis: "private text")
                    ]))
        }
        let runs = await store.load()
        XCTAssertEqual(runs.map(\.device), ["d1", "d2"])
        XCTAssertNil(runs.last?.results.first?.hypothesis)
    }

    func testTheScreenSelectsReadyEnginesRunsAndSavesTheRun() async throws {
        let ready = UnloadingSpeech(id: SpeechEngineCapabilityRegistry.parakeetEngineID, text: "the quick brown fox")
        let missing = UnloadingSpeech(
            id: SpeechEngineCapabilityRegistry.whisperKitEngineID, text: "x", status: .notDownloaded)
        let parakeet = SpeechEngineVariantKey(engineID: SpeechEngineCapabilityRegistry.parakeetEngineID, variant: "v3")
        let whisper = SpeechEngineVariantKey(
            engineID: SpeechEngineCapabilityRegistry.whisperKitEngineID, variant: "base")
        let router = SpeechEngineRouter(engines: [
            .init(key: parakeet, engine: ready), .init(key: whisper, engine: missing),
        ])
        let reference = folder.appendingPathComponent("Benchmark", isDirectory: true)
        try FileManager.default.createDirectory(at: reference, withIntermediateDirectories: true)
        try Data(
            #"{"version":1,"entries":[{"id":"fox","file":"fox.m4a","voice":"Samantha","text":"The quick brown fox."}]}"#
                .utf8
        ).write(to: reference.appendingPathComponent(ASRBenchmarkReferenceSet.manifestName))
        try Data(repeating: 7, count: 64).write(to: reference.appendingPathComponent("fox.m4a"))
        let model = ASRBenchmarkViewModel(
            router: router, runner: runner(),
            store: ASRBenchmarkStore(fileURL: folder.appendingPathComponent("runs.json")), referenceFolder: reference,
            importFolder: folder.appendingPathComponent("imports"), device: "Test", appBuild: "1.0 (1)")

        await model.refresh()
        XCTAssertEqual(model.referenceItems.map(\.id), ["fox"])
        XCTAssertEqual(model.selected, [parakeet], "only ready engines are selected")
        XCTAssertEqual(model.engines.first { $0.key == whisper }?.unavailableReason, "Not downloaded")
        XCTAssertTrue(model.canRun)

        model.run()
        XCTAssertTrue(model.isRunning)
        await model.waitForRun()
        XCTAssertFalse(model.isRunning)
        XCTAssertNil(model.lastError)
        XCTAssertEqual(model.latest?.results.first?.wordErrorRate?.rate, 0)
        XCTAssertEqual(model.latest?.device, "Test")

        let files = try model.exportFiles(to: folder.appendingPathComponent("export"))
        XCTAssertEqual(files.map(\.pathExtension), ["csv", "json"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: files[0].path))
    }
}

/// Thread-safe append-only log for values sampled from `@Sendable` closures.
private final class LockedLog<Element: Sendable>: @unchecked Sendable {
    // @unchecked Sendable: `storage` is only touched while `lock` is held.
    private let lock = NSLock()
    private var storage: [Element] = []

    func append(_ element: Element) { lock.withLock { storage.append(element) } }
    var values: [Element] { lock.withLock { storage } }
}
