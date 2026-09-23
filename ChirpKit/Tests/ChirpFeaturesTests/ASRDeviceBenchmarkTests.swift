import ChirpCore
import XCTest

@testable import ChirpFeatures

/// The DEBUG on-device benchmark (fix/asr-review): the launch argument, the report the script reads, and the run with
/// fake engines (skips, downloads, permission, failures). The real run is the controller's, on the iPhone.
final class ASRDeviceBenchmarkTests: XCTestCase {
    /// A speech engine with a scriptable model state, download, availability and permission.
    actor ScriptedEngine: SpeechEngine, SpeechEngineUnloading, SpeechEngineAvailabilityReporting,
        SpeechEnginePermissionReporting
    {
        nonisolated let descriptor: EngineDescriptor
        private var status: ModelAssetStatus
        private let text: String
        private let unavailable: String?
        private let permissionPrompt: Bool
        private let downloadFails: Bool
        private(set) var downloads = 0

        init(
            id: String, status: ModelAssetStatus = .ready(bytesOnDisk: 1), text: String = "the quick brown fox",
            unavailable: String? = nil, permissionPrompt: Bool = false, downloadFails: Bool = false
        ) {
            descriptor = EngineDescriptor(
                id: id, kind: .speech, provider: "Test", displayName: id, locality: .onDevice, license: "MIT")
            self.status = status
            self.text = text
            self.unavailable = unavailable
            self.permissionPrompt = permissionPrompt
            self.downloadFails = downloadFails
        }

        func unavailableReason() async -> String? { unavailable }
        func needsPermissionPrompt() async -> Bool { permissionPrompt }
        func unloadModels() async {}
        func assetStatus() async -> ModelAssetStatus { status }
        func downloadAssets(progress: @escaping @Sendable (Double) -> Void) async throws {
            downloads += 1
            if downloadFails { throw SpeechEngineError.underlying("synthetic: no network") }
            status = .ready(bytesOnDisk: 1)
        }
        func deleteAssets() async throws {}
        func prepare() async throws {}
        func transcribe(
            fileAt url: URL, options: SpeechTranscriptionOptions, progress: @escaping @Sendable (Double) -> Void
        ) async throws -> SpeechResult {
            try await Task.sleep(for: .milliseconds(2))
            return SpeechResult(text: text, words: [], language: "en", engineID: descriptor.id, engineVariant: nil)
        }
    }

    private var folder: URL!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ASRDeviceBenchmarkTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: - The launch argument

    func testTheArgumentIsParsedInOrderWithoutRepeats() {
        typealias Request = ASRDeviceBenchmarkRequest
        XCTAssertNil(Request.parse(["iChirp", "-ChirpSmoke", "transcribe-sample"]), "absent: no benchmark")
        XCTAssertEqual(
            Request.parse(["iChirp", "-ChirpBenchmarkDevice", "parakeet,whisper-base,whisper-turbo,apple-speech"]),
            .success(Request(engines: [.parakeet, .whisperBase, .whisperTurbo, .appleSpeech])))
        XCTAssertEqual(
            Request.parse(["-ChirpBenchmarkDevice", " Whisper-Turbo , parakeet,,whisper-turbo "]),
            .success(Request(engines: [.whisperTurbo, .parakeet])))
        XCTAssertEqual(
            Request.parse(["-ChirpBenchmarkDevice", "apple-speech,all"]),
            .success(Request(engines: [.appleSpeech, .parakeet, .whisperBase, .whisperTurbo])))
    }

    func testABadArgumentIsAFailureWithAReadableReason() {
        typealias Request = ASRDeviceBenchmarkRequest
        XCTAssertEqual(Request.parse(["-ChirpBenchmarkDevice"]), .failure(.missingList))
        XCTAssertEqual(Request.parse(["-ChirpBenchmarkDevice", "-ChirpSmoke"]), .failure(.missingList))
        XCTAssertEqual(Request.parse(["-ChirpBenchmarkDevice", " , "]), .failure(.missingList))
        XCTAssertEqual(
            Request.parse(["-ChirpBenchmarkDevice", "parakeet,whisper-tiny"]), .failure(.unknownEngine("whisper-tiny")))
        XCTAssertTrue(
            Request.ParseError.unknownEngine("x").localizedDescription.contains("whisper-turbo"),
            "the reason lists the known names")
    }

    func testEveryNameMapsToTheRegistryRowTheAppRegisters() {
        for engine in ASRDeviceBenchmarkRequest.Engine.allCases {
            XCTAssertNotNil(
                SpeechEngineCapabilityRegistry.capabilitiesIfPresent(for: engine.key), "\(engine.rawValue) has a row")
        }
    }

    // MARK: - The report

    func testTheReportRoundTripsWithTheFieldsTheScriptReads() throws {
        let report = ASRDeviceBenchmarkReport(
            status: .completed, requested: ["parakeet"], device: "iPhone16,1 · iOS 26.2", deviceModel: "iPhone16,1",
            build: "0.1.0 (1) · abc123 · fix/asr-review · 2026-09-22T23:00:00Z", buildSHA: "abc123",
            startedAt: Date(timeIntervalSince1970: 1_000), finishedAt: Date(timeIntervalSince1970: 1_060),
            engines: [
                .init(
                    name: "parakeet", key: "fluidaudio.parakeet-tdt:v3", displayName: "Parakeet v3",
                    outcome: .measured, wordErrorRate: 0.05, realTimeFactor: 0.02, timesRealTime: 50, loadMs: 800,
                    peakMemoryBytes: 600_000_000, availableMemoryBeforeLoadBytes: 5_800_000_000,
                    loadPeakMemoryBytes: 550_000_000, footprintBeforeLoadBytes: 150_000_000)
            ])
        let data = try report.encoded()
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["format"] as? String, "ichirp.asr-device-benchmark/v1")
        XCTAssertEqual(json["status"] as? String, "completed")
        XCTAssertEqual(json["buildSHA"] as? String, "abc123")
        XCTAssertEqual(json["deviceModel"] as? String, "iPhone16,1")
        XCTAssertEqual(json["startedAt"] as? String, "1970-01-01T00:16:40Z")
        let engine = try XCTUnwrap((json["engines"] as? [[String: Any]])?.first)
        for key in [
            "name", "outcome", "wordErrorRate", "timesRealTime", "loadMs", "peakMemoryBytes",
            "availableMemoryBeforeLoadBytes", "loadPeakMemoryBytes", "footprintBeforeLoadBytes",
        ] {
            XCTAssertNotNil(engine[key], key)
        }
        XCTAssertEqual(try ASRDeviceBenchmarkReport.decode(data), report)
    }

    // MARK: - The run

    private func referenceItems() throws -> [ASRBenchmarkItem] {
        let url = folder.appendingPathComponent("fox.m4a")
        try Data(repeating: 7, count: 64).write(to: url)
        return [ASRBenchmarkItem(id: "fox", title: "fox", audioURL: url, referenceText: "The quick brown fox.")]
    }

    private func benchmark(
        _ engines: [(ASRDeviceBenchmarkRequest.Engine, ScriptedEngine)], items: [ASRBenchmarkItem],
        router made: SpeechEngineRouter? = nil, availableMemory: @escaping @Sendable () -> UInt64? = { nil }
    ) -> ASRDeviceBenchmark {
        let router = made ?? Self.router(engines)
        let runner = ASRBenchmarkRunner(
            scheduler: SpeechJobScheduler(), normalizer: FakeNormalizer(), memory: { 500_000_000 },
            availableMemory: availableMemory, workDirectory: folder, sampleInterval: .milliseconds(1))
        return ASRDeviceBenchmark(
            router: router, runner: runner, items: items, device: "Test · iOS 26", deviceModel: "Test",
            build: "0.1.0 (1) · abc123", buildSHA: "abc123", physicalMemoryBytes: 12_000_000_000,
            availableMemory: availableMemory)
    }

    private static func router(
        _ engines: [(ASRDeviceBenchmarkRequest.Engine, ScriptedEngine)],
        onSelectionChange: @escaping @Sendable (SpeechRouteSelection) -> Void = { _ in }
    ) -> SpeechEngineRouter {
        SpeechEngineRouter(
            engines: engines.map {
                let key =
                    $0.0 == .parakeet
                    ? SpeechEngineVariantKey(engineID: SpeechEngineCapabilityRegistry.parakeetEngineID, variant: "v3")
                    : $0.0.key
                return SpeechEngineRouter.Registration(key: key, engine: $0.1)
            }, onSelectionChange: onSelectionChange)
    }

    func testReadyEnginesAreMeasuredMissingOnesDownloadedAndAPermissionPromptIsSkipped() async throws {
        let parakeet = ScriptedEngine(id: SpeechEngineCapabilityRegistry.parakeetEngineID)
        let base = ScriptedEngine(
            id: SpeechEngineCapabilityRegistry.whisperKitEngineID, status: .notDownloaded, text: "the quick brown")
        let apple = ScriptedEngine(
            id: SpeechEngineCapabilityRegistry.appleSpeechEngineID, status: .notDownloaded, permissionPrompt: true)
        let bench = benchmark(
            [(.parakeet, parakeet), (.whisperBase, base), (.appleSpeech, apple)], items: try referenceItems())
        let lines = LockedLines()

        let report = await bench.run(
            ASRDeviceBenchmarkRequest(engines: [.parakeet, .whisperBase, .appleSpeech, .whisperTurbo]),
            log: { lines.append($0) })

        XCTAssertEqual(report.status, .completed, report.error ?? "")
        XCTAssertEqual(report.requested, ["parakeet", "whisper-base", "apple-speech", "whisper-turbo"])
        let byName = Dictionary(uniqueKeysWithValues: report.engines.map { ($0.name, $0) })
        XCTAssertEqual(byName["parakeet"]?.outcome, .measured)
        XCTAssertEqual(byName["parakeet"]?.wordErrorRate, 0)
        XCTAssertEqual(byName["parakeet"]?.peakMemoryBytes, 500_000_000)
        XCTAssertNotNil(byName["parakeet"]?.timesRealTime)
        XCTAssertEqual(byName["whisper-base"]?.outcome, .measured)
        XCTAssertEqual(byName["whisper-base"]?.downloaded, true)
        XCTAssertEqual(byName["whisper-base"]?.wordErrorRate ?? 0, 0.25, accuracy: 0.0001, "one of four words missing")
        XCTAssertEqual(byName["apple-speech"]?.outcome, .skipped)
        XCTAssertEqual(byName["apple-speech"]?.reason, "permission-needed")
        XCTAssertEqual(byName["whisper-turbo"]?.outcome, .skipped)
        XCTAssertEqual(byName["whisper-turbo"]?.reason, "not-in-build")
        let appleDownloads = await apple.downloads
        XCTAssertEqual(appleDownloads, 0, "never waits on a prompt nobody can tap")
        let baseDownloads = await base.downloads
        XCTAssertEqual(baseDownloads, 1)
        XCTAssertEqual(report.run?.results.count, 2, "two engines × one recording")
        XCTAssertTrue(lines.all.contains { $0.hasPrefix("bench_skip engine=apple-speech reason=permission-needed") })
    }

    func testAFailedDownloadOrAnUnavailableEngineIsReportedAndTheOthersStillRun() async throws {
        let parakeet = ScriptedEngine(id: SpeechEngineCapabilityRegistry.parakeetEngineID)
        let turbo = ScriptedEngine(
            id: SpeechEngineCapabilityRegistry.whisperKitEngineID, status: .notDownloaded, downloadFails: true)
        let apple = ScriptedEngine(
            id: SpeechEngineCapabilityRegistry.appleSpeechEngineID, unavailable: "Needs an iPhone.")
        let bench = benchmark(
            [(.parakeet, parakeet), (.whisperTurbo, turbo), (.appleSpeech, apple)], items: try referenceItems())

        let report = await bench.run(ASRDeviceBenchmarkRequest(engines: [.whisperTurbo, .appleSpeech, .parakeet]))

        XCTAssertEqual(report.status, .completed)
        let byName = Dictionary(uniqueKeysWithValues: report.engines.map { ($0.name, $0) })
        XCTAssertEqual(byName["whisper-turbo"]?.outcome, .failed)
        XCTAssertEqual(byName["whisper-turbo"]?.reason, "download-failed: synthetic: no network")
        XCTAssertEqual(byName["apple-speech"]?.outcome, .skipped)
        XCTAssertEqual(byName["apple-speech"]?.reason, "unavailable: Needs an iPhone.")
        XCTAssertEqual(byName["parakeet"]?.outcome, .measured)
    }

    func testNothingRunnableOrNoReferenceSetFailsTheRunWithAReason() async throws {
        let turbo = ScriptedEngine(
            id: SpeechEngineCapabilityRegistry.whisperKitEngineID, status: .notDownloaded, downloadFails: true)
        let failed = await benchmark([(.whisperTurbo, turbo)], items: try referenceItems())
            .run(ASRDeviceBenchmarkRequest(engines: [.whisperTurbo]))
        XCTAssertEqual(failed.status, .failed)
        XCTAssertEqual(failed.error, "no requested engine could run")

        let empty = await benchmark(
            [(.parakeet, ScriptedEngine(id: SpeechEngineCapabilityRegistry.parakeetEngineID))], items: []
        )
        .run(ASRDeviceBenchmarkRequest(engines: [.parakeet]))
        XCTAssertEqual(empty.status, .failed)
        XCTAssertEqual(empty.error, "the synthetic reference set is missing from this build")
    }

    // MARK: - fix/speech-memory-fit

    func testEachEngineRecordsTheMemoryBeforeItsLoadAndACheckpointNamesTheEngineRunning() async throws {
        let parakeet = ScriptedEngine(id: SpeechEngineCapabilityRegistry.parakeetEngineID)
        let base = ScriptedEngine(id: SpeechEngineCapabilityRegistry.whisperKitEngineID)
        let checkpoints = LockedReports()
        let report = await benchmark(
            [(.parakeet, parakeet), (.whisperBase, base)], items: try referenceItems(),
            availableMemory: { 5_800_000_000 }
        )
        .run(ASRDeviceBenchmarkRequest(engines: [.parakeet, .whisperBase]), checkpoint: { checkpoints.append($0) })

        XCTAssertEqual(report.status, .completed)
        XCTAssertNil(report.runningEngine)
        for engine in report.engines {
            XCTAssertEqual(engine.availableMemoryBeforeLoadBytes, 5_800_000_000, engine.name)
            XCTAssertEqual(engine.loadPeakMemoryBytes, 500_000_000, engine.name)
            XCTAssertEqual(engine.footprintBeforeLoadBytes, 500_000_000, engine.name)
        }
        // Before each engine: running, that engine named, its reading already in place (a file left by iOS ending
        // the app mid-load still says which engine and how much memory). After each: its numbers, nothing running.
        let all = checkpoints.all
        XCTAssertEqual(all.map(\.runningEngine), ["parakeet", nil, "whisper-base", nil])
        XCTAssertTrue(all.allSatisfy { $0.status == .running })
        XCTAssertEqual(all[0].engines.first { $0.name == "parakeet" }?.availableMemoryBeforeLoadBytes, 5_800_000_000)
        XCTAssertNil(all[0].engines.first { $0.name == "parakeet" }?.wordErrorRate)
        XCTAssertEqual(all[1].engines.first { $0.name == "parakeet" }?.outcome, .measured)
        XCTAssertEqual(all[2].engines.first { $0.name == "whisper-base" }?.outcome, .pending, "not measured yet")
    }

    func testTheBenchmarkNeverChangesTheSavedRoutes() async throws {
        let parakeet = ScriptedEngine(id: SpeechEngineCapabilityRegistry.parakeetEngineID)
        let base = ScriptedEngine(id: SpeechEngineCapabilityRegistry.whisperKitEngineID)
        let saved = LockedLines()
        let router = Self.router(
            [(.parakeet, parakeet), (.whisperBase, base)], onSelectionChange: { saved.append("\($0)") })
        let before = router.selection
        let report = await benchmark([], items: try referenceItems(), router: router)
            .run(ASRDeviceBenchmarkRequest(engines: [.whisperBase, .parakeet]))
        XCTAssertEqual(report.engines.map(\.outcome), [.measured, .measured])
        XCTAssertEqual(router.selection, before)
        XCTAssertEqual(saved.all, [], "nothing saved: the owner's routes are untouched")
    }
}

/// Thread-safe list of checkpointed reports.
private final class LockedReports: @unchecked Sendable {
    // @unchecked Sendable: `reports` is only touched while `lock` is held.
    private let lock = NSLock()
    private var reports: [ASRDeviceBenchmarkReport] = []

    func append(_ report: ASRDeviceBenchmarkReport) { lock.withLock { reports.append(report) } }
    var all: [ASRDeviceBenchmarkReport] { lock.withLock { reports } }
}

/// Thread-safe list of logged lines.
private final class LockedLines: @unchecked Sendable {
    // @unchecked Sendable: `lines` is only touched while `lock` is held.
    private let lock = NSLock()
    private var lines: [String] = []

    func append(_ line: String) { lock.withLock { lines.append(line) } }
    var all: [String] { lock.withLock { lines } }
}
