import ChirpCore
import ChirpText
import Foundation

/// The DEBUG on-device benchmark's request (fix/asr-review): the launch argument
/// `-ChirpBenchmarkDevice parakeet,whisper-base,whisper-turbo,apple-speech` (or `all`) that
/// `scripts/device_benchmark.sh` passes. Parsing lives here so it is tested on the Mac.
public struct ASRDeviceBenchmarkRequest: Equatable, Sendable {
    public static let launchArgument = "-ChirpBenchmarkDevice"

    /// The engine names the argument accepts, one per engine build the app registers.
    public enum Engine: String, CaseIterable, Sendable, Codable {
        case parakeet
        case whisperBase = "whisper-base"
        case whisperTurbo = "whisper-turbo"
        case appleSpeech = "apple-speech"

        /// The registry key the router resolves (Parakeet: whichever variant this launch runs).
        public var key: SpeechEngineVariantKey {
            switch self {
            case .parakeet: SpeechEngineVariantKey(engineID: SpeechEngineCapabilityRegistry.parakeetEngineID)
            case .whisperBase:
                SpeechEngineVariantKey(engineID: SpeechEngineCapabilityRegistry.whisperKitEngineID, variant: "base")
            case .whisperTurbo:
                SpeechEngineVariantKey(
                    engineID: SpeechEngineCapabilityRegistry.whisperKitEngineID, variant: "large-v3-turbo")
            case .appleSpeech: SpeechEngineVariantKey(engineID: SpeechEngineCapabilityRegistry.appleSpeechEngineID)
            }
        }
    }

    public enum ParseError: Error, Equatable, LocalizedError {
        /// The argument is there but no list follows it.
        case missingList
        case unknownEngine(String)

        public var errorDescription: String? {
            switch self {
            case .missingList:
                "\(ASRDeviceBenchmarkRequest.launchArgument) needs a comma-separated list, e.g. parakeet,whisper-base"
            case .unknownEngine(let name):
                "unknown engine '\(name)' (known: \(Engine.allCases.map(\.rawValue).joined(separator: ", ")), all)"
            }
        }
    }

    /// In the order asked, without repeats.
    public var engines: [Engine]

    public init(engines: [Engine]) {
        self.engines = engines
    }

    /// Nil when the argument is absent; a failure when it is present but unusable.
    public static func parse(_ arguments: [String]) -> Result<ASRDeviceBenchmarkRequest, ParseError>? {
        guard let index = arguments.firstIndex(of: launchArgument) else { return nil }
        guard index + 1 < arguments.count, !arguments[index + 1].hasPrefix("-") else { return .failure(.missingList) }
        let names = arguments[index + 1].split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces).lowercased()
        }.filter { !$0.isEmpty }
        guard !names.isEmpty else { return .failure(.missingList) }
        var engines: [Engine] = []
        for name in names {
            let chosen: [Engine]
            if name == "all" {
                chosen = Engine.allCases
            } else if let engine = Engine(rawValue: name) {
                chosen = [engine]
            } else {
                return .failure(.unknownEngine(name))
            }
            for engine in chosen where !engines.contains(engine) { engines.append(engine) }
        }
        return .success(ASRDeviceBenchmarkRequest(engines: engines))
    }
}

/// What the DEBUG device benchmark writes (`Documents/asr-device-benchmark.json`) and `scripts/device_benchmark.sh`
/// reads: where and which build, one line per requested engine, and the full run. Synthetic reference set only.
public struct ASRDeviceBenchmarkReport: Codable, Sendable, Equatable {
    public static let formatName = "ichirp.asr-device-benchmark/v1"
    public static let fileName = "asr-device-benchmark.json"

    public enum Status: String, Codable, Sendable {
        case running, completed, failed
    }

    public enum Outcome: String, Codable, Sendable {
        /// Ran over the reference set (some recordings may still have failed: see `failures`).
        case measured
        /// Not run, for a reason that is not a failure of the engine (`reason`: permission-needed, unavailable…).
        case skipped
        /// The download, the load or every recording failed (`reason`).
        case failed
        /// fix/speech-memory-fit: ready to run, not measured yet (only in a checkpoint written while the run goes on).
        case pending
    }

    public struct EngineReport: Codable, Sendable, Equatable {
        /// The name from the launch argument, e.g. "whisper-turbo".
        public var name: String
        /// The registered key, e.g. "argmax.whisperkit:large-v3-turbo".
        public var key: String
        public var displayName: String
        public var outcome: Outcome
        public var reason: String?
        /// Its model was downloaded by this run.
        public var downloaded: Bool
        public var downloadMs: Int?
        /// Corpus word error rate over the reference set (0.05 = 5 %).
        public var wordErrorRate: Double?
        /// Transcription time ÷ audio length (lower is faster).
        public var realTimeFactor: Double?
        /// Audio length ÷ transcription time ("× real time"; higher is faster).
        public var timesRealTime: Double?
        /// Model load after the benchmark unloaded it.
        public var loadMs: Int?
        /// The app's peak physical footprint while it loaded and ran.
        public var peakMemoryBytes: UInt64?
        /// fix/speech-memory-fit: what iOS let the app use (`os_proc_available_memory`) right before this engine's
        /// model load. Written in a checkpoint before the engine starts (a reading just before its run), then replaced
        /// by the runner's reading inside the job, right before the load.
        public var availableMemoryBeforeLoadBytes: UInt64?
        /// fix/speech-memory-fit: the app's peak footprint during the load alone (on a first load, the Core ML
        /// compile): the device number for the registry's first-load peak.
        public var loadPeakMemoryBytes: UInt64?
        /// Recordings that failed.
        public var failures: Int

        public init(
            name: String, key: String, displayName: String, outcome: Outcome, reason: String? = nil,
            downloaded: Bool = false, downloadMs: Int? = nil, wordErrorRate: Double? = nil,
            realTimeFactor: Double? = nil, timesRealTime: Double? = nil, loadMs: Int? = nil,
            peakMemoryBytes: UInt64? = nil, availableMemoryBeforeLoadBytes: UInt64? = nil,
            loadPeakMemoryBytes: UInt64? = nil, failures: Int = 0
        ) {
            self.name = name
            self.key = key
            self.displayName = displayName
            self.outcome = outcome
            self.reason = reason
            self.downloaded = downloaded
            self.downloadMs = downloadMs
            self.wordErrorRate = wordErrorRate
            self.realTimeFactor = realTimeFactor
            self.timesRealTime = timesRealTime
            self.loadMs = loadMs
            self.peakMemoryBytes = peakMemoryBytes
            self.availableMemoryBeforeLoadBytes = availableMemoryBeforeLoadBytes
            self.loadPeakMemoryBytes = loadPeakMemoryBytes
            self.failures = failures
        }
    }

    public var format: String
    public var status: Status
    public var error: String?
    public var requested: [String]
    /// "iPhone16,1 · iOS 26.2".
    public var device: String
    /// The model identifier, e.g. "iPhone16,1".
    public var deviceModel: String
    /// `BuildIdentity.summary`; contains the build date, which the script uses to reject a file from an older install.
    public var build: String
    /// The git commit the build was stamped with.
    public var buildSHA: String
    public var startedAt: Date
    public var finishedAt: Date?
    /// fix/speech-memory-fit: the engine (launch-argument name) whose run had started when this file was written; nil
    /// once the run finished. A file left `running` with this set means the app stopped during that engine — for a
    /// model load, most likely iOS closing the app for memory — and its entry keeps the memory available before it.
    public var runningEngine: String?
    public var engines: [EngineReport]
    /// Every engine × recording result (the synthetic set's recognized text included).
    public var run: ASRBenchmarkRun?

    public init(
        status: Status, error: String? = nil, requested: [String], device: String, deviceModel: String,
        build: String, buildSHA: String, startedAt: Date, finishedAt: Date? = nil, engines: [EngineReport] = [],
        run: ASRBenchmarkRun? = nil
    ) {
        self.format = Self.formatName
        self.status = status
        self.error = error
        self.requested = requested
        self.device = device
        self.deviceModel = deviceModel
        self.build = build
        self.buildSHA = buildSHA
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.engines = engines
        self.run = run
    }

    /// Pretty, sorted keys, ISO 8601 dates.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> ASRDeviceBenchmarkReport {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ASRDeviceBenchmarkReport.self, from: data)
    }
}

/// The DEBUG on-device benchmark (fix/asr-review, for the controller's iPhone numbers): for each requested engine it
/// skips what cannot run here (not in this build, over the memory budget, not on this device, or a system permission
/// prompt nobody can tap: `permission-needed`), downloads a missing model over the network (the controller asked for
/// it with the launch argument), then runs `ASRBenchmarkRunner` over the synthetic reference set and reports WER,
/// speed, load time and peak memory per engine. It never changes the saved routes and never shows UI.
///
/// fix/speech-memory-fit: each engine also reports the memory iOS let the app use right before its load and the peak
/// during the load alone. The engines run one `ASRBenchmarkRunner` call at a time, with a `checkpoint` before each
/// one (`runningEngine` and the reading just before it), so a file from a run iOS ended mid-load still says which
/// engine was loading and with how much memory. A load the engine refuses as not fitting is that engine's reason.
public struct ASRDeviceBenchmark: Sendable {
    public typealias Log = @Sendable (String) -> Void

    private let router: SpeechEngineRouter
    private let runner: ASRBenchmarkRunner
    private let items: [ASRBenchmarkItem]
    private let device: String
    private let deviceModel: String
    private let build: String
    private let buildSHA: String
    private let physicalMemoryBytes: UInt64
    private let availableMemory: ASRBenchmarkRunner.MemoryReader

    /// - Parameter availableMemory: what iOS lets the app use now (`MemoryProbe.availableBytes`), read for each
    ///   engine's checkpoint (the runner takes its own reading right before the load).
    public init(
        router: SpeechEngineRouter, runner: ASRBenchmarkRunner, items: [ASRBenchmarkItem], device: String,
        deviceModel: String, build: String, buildSHA: String,
        physicalMemoryBytes: UInt64 = ProcessInfo.processInfo.physicalMemory,
        availableMemory: @escaping ASRBenchmarkRunner.MemoryReader = { nil }
    ) {
        self.router = router
        self.runner = runner
        self.items = items
        self.device = device
        self.deviceModel = deviceModel
        self.build = build
        self.buildSHA = buildSHA
        self.physicalMemoryBytes = physicalMemoryBytes
        self.availableMemory = availableMemory
    }

    /// The report written before anything runs (status `running`), so a reader can tell "started" from "never ran".
    public func placeholder(for request: ASRDeviceBenchmarkRequest, startedAt: Date) -> ASRDeviceBenchmarkReport {
        ASRDeviceBenchmarkReport(
            status: .running, requested: request.engines.map(\.rawValue), device: device, deviceModel: deviceModel,
            build: build, buildSHA: buildSHA, startedAt: startedAt)
    }

    /// Runs the request and returns the finished report (`completed`, or `failed` with `error` when nothing could be
    /// measured at all). Cancellation ends it as `failed` ("cancelled"). `checkpoint` receives the report (status
    /// `running`) before each engine's run and after its numbers are in; the app writes it to the results file.
    public func run(
        _ request: ASRDeviceBenchmarkRequest, log: Log = { _ in },
        checkpoint: @Sendable (ASRDeviceBenchmarkReport) -> Void = { _ in }
    ) async -> ASRDeviceBenchmarkReport {
        var report = placeholder(for: request, startedAt: Date())
        guard !items.isEmpty else {
            return finished(report, error: "the synthetic reference set is missing from this build")
        }
        var reports: [ASRDeviceBenchmarkReport.EngineReport] = []
        var runnable: [ASRBenchmarkEngine] = []
        for engine in request.engines {
            if Task.isCancelled { return finished(report, error: "cancelled") }
            let (entry, benchmarkEngine) = await prepare(engine, log: log)
            reports.append(entry)
            if let benchmarkEngine { runnable.append(benchmarkEngine) }
        }
        report.engines = reports
        guard !runnable.isEmpty else {
            let failed = reports.contains { $0.outcome == .failed }
            // Every engine skipped (e.g. only Apple Speech, waiting on a permission) is still a completed run.
            return failed ? finished(report, error: "no requested engine could run") : finished(report, error: nil)
        }
        log("bench_run engines=\(runnable.map(\.key.description).joined(separator: ",")) items=\(items.count)")
        var results: [ASRBenchmarkResult] = []
        for engine in runnable {
            // A checkpoint first: if iOS ends the app during this engine's load, the file still says which one and
            // how much memory it had.
            let before = availableMemory()
            report.runningEngine = reports.first { $0.key == engine.key.description }?.name
            report.engines = report.engines.map {
                var entry = $0
                if entry.key == engine.key.description { entry.availableMemoryBeforeLoadBytes = before }
                return entry
            }
            checkpoint(report)
            let availableMB = before.map { String($0 / 1_048_576) } ?? "unknown"
            log("bench_engine_start engine=\(engine.key.description) available_mb=\(availableMB)")
            do {
                results += try await runner.run(engines: [engine], items: items)
            } catch {
                report.runningEngine = nil
                return finished(report, error: error is CancellationError ? "cancelled" : error.localizedDescription)
            }
            let summaries = ASRBenchmarkRun(
                startedAt: report.startedAt, device: device, appBuild: build, results: results
            ).summaries
            report.engines = report.engines.map { Self.merging($0, summaries: summaries, results: results) }
            report.runningEngine = nil
            checkpoint(report)
        }
        let run = ASRBenchmarkRun(startedAt: report.startedAt, device: device, appBuild: build, results: results)
        report.run = run
        report.engines = report.engines.map { Self.merging($0, summaries: run.summaries, results: results) }
        return finished(report, error: nil)
    }

    // MARK: - Steps

    /// One requested engine: skipped, failed, or ready to run (downloaded first when its model is missing).
    private func prepare(
        _ requested: ASRDeviceBenchmarkRequest.Engine, log: Log
    ) async -> (ASRDeviceBenchmarkReport.EngineReport, ASRBenchmarkEngine?) {
        let name = requested.rawValue
        guard let key = router.registeredKey(for: requested.key), let engine = router.registeredEngine(for: key)
        else {
            return (
                .init(
                    name: name, key: requested.key.description, displayName: name, outcome: .skipped,
                    reason: "not-in-build"), nil
            )
        }
        let row = SpeechEngineCapabilityRegistry.capabilitiesIfPresent(for: key)
        let displayName = row?.displayName ?? engine.descriptor.displayName
        var entry = ASRDeviceBenchmarkReport.EngineReport(
            name: name, key: key.description, displayName: displayName, outcome: .skipped)
        if let row,
            let reason = SpeechEngineCapabilityRegistry.memoryRequirementStatus(
                for: row, physicalMemoryBytes: physicalMemoryBytes
            ).insufficientMemoryMessage
        {
            entry.reason = "over-memory-budget: \(reason)"
            return (entry, nil)
        }
        if let reporting = engine as? any SpeechEngineAvailabilityReporting,
            let reason = await reporting.unavailableReason()
        {
            entry.reason = "unavailable: \(reason)"
            return (entry, nil)
        }
        if let permission = engine as? any SpeechEnginePermissionReporting, await permission.needsPermissionPrompt() {
            // A system prompt nobody can tap from the command line: skip, never wait on it.
            entry.reason = "permission-needed"
            log("bench_skip engine=\(name) reason=permission-needed")
            return (entry, nil)
        }
        if case .ready = await engine.assetStatus() {
            entry.outcome = .pending
            return (entry, ASRBenchmarkEngine(key: key, name: displayName, engine: engine))
        }
        log("bench_download engine=\(name) (requested by -ChirpBenchmarkDevice; the only download without a tap)")
        let clock = ContinuousClock()
        let start = clock.now
        do {
            try await engine.downloadAssets { _ in }
        } catch {
            entry.outcome = .failed
            entry.reason = "download-failed: \(error.localizedDescription)"
            log("bench_download_failed engine=\(name)")
            return (entry, nil)
        }
        entry.downloaded = true
        entry.downloadMs = ASRBenchmarkRunner.milliseconds(clock.now - start)
        let status = await engine.assetStatus()
        guard case .ready = status else {
            entry.outcome = .failed
            entry.reason = "not-ready-after-download: \(status)"
            return (entry, nil)
        }
        log("bench_download_done engine=\(name) ms=\(entry.downloadMs ?? 0)")
        entry.outcome = .pending
        return (entry, ASRBenchmarkEngine(key: key, name: displayName, engine: engine))
    }

    /// The engine's numbers from the run's summary; `failed` when every recording failed.
    static func merging(
        _ entry: ASRDeviceBenchmarkReport.EngineReport, summaries: [ASRBenchmarkRun.EngineSummary],
        results: [ASRBenchmarkResult]
    ) -> ASRDeviceBenchmarkReport.EngineReport {
        guard let summary = summaries.first(where: { $0.engineKey == entry.key }) else { return entry }
        var merged = entry
        let own = results.filter { $0.engineKey == entry.key }
        merged.wordErrorRate = summary.wordErrorRate?.rate
        merged.realTimeFactor = summary.realTimeFactor
        merged.timesRealTime = summary.realTimeFactor.flatMap { $0 > 0 ? 1 / $0 : nil }
        merged.loadMs = summary.loadMs
        merged.peakMemoryBytes = summary.peakMemoryBytes
        merged.availableMemoryBeforeLoadBytes =
            summary.availableMemoryBeforeLoadBytes ?? entry.availableMemoryBeforeLoadBytes
        merged.loadPeakMemoryBytes = summary.loadPeakMemoryBytes
        merged.failures = summary.failures
        if !own.isEmpty, summary.failures == own.count {
            merged.outcome = .failed
            merged.reason = own.compactMap(\.error).first ?? "every recording failed"
        } else {
            merged.outcome = .measured
        }
        return merged
    }

    private func finished(_ report: ASRDeviceBenchmarkReport, error: String?) -> ASRDeviceBenchmarkReport {
        var report = report
        report.status = error == nil ? .completed : .failed
        report.error = error
        report.finishedAt = Date()
        return report
    }
}
