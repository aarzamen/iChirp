#if DEBUG
import ChirpAudio
import ChirpCore
import ChirpFeatures
import Foundation

/// DEBUG-only: the on-device ASR benchmark the controller runs with `scripts/device_benchmark.sh`
/// (fix/asr-review). Launched with `-ChirpBenchmarkDevice parakeet,whisper-base,whisper-turbo,apple-speech` (or
/// `all`), it downloads each named engine's missing model (the controller asked for it; logged), runs the ASR
/// benchmark over the bundled synthetic reference set, and writes `Documents/asr-device-benchmark.json`
/// (`ASRDeviceBenchmarkReport`: WER, × real time, load time and peak memory per engine, the device model and the build
/// SHA). It logs exactly one final line, `BENCH DONE <path>` or `BENCH FAIL <reason>`.
///
/// fix/speech-memory-fit: each engine also gets `os_proc_available_memory()` right before its model load and the peak
/// footprint during the load alone, and the file is rewritten (status `running`, `runningEngine`) before each engine,
/// so a run iOS ends during a model load still says which engine and how much memory it had.
///
/// - Apple Speech is skipped with `permission-needed` while iOS has never asked for Speech Recognition: that prompt
///   cannot be tapped from the command line, and nothing here waits on UI.
/// - The saved Live text and Transcripts routes are never read or changed; each engine is used directly.
/// - The run is also added to Settings → Speech engines → Benchmark's history.
/// - The phone stays awake while it runs (`DownloadKeepAlive`); keep the app in the foreground.
@MainActor enum DeviceBenchmarkLaunch {
    private static let logger = Log.logger("device-benchmark")
    /// Keeps the one run alive independently of any view.
    private static var task: Task<Void, Never>?

    /// `Documents/asr-device-benchmark.json`.
    nonisolated static var resultURL: URL {
        URL.documentsDirectory.appendingPathComponent(ASRDeviceBenchmarkReport.fileName, isDirectory: false)
    }

    /// Starts the run when the launch argument is present (once per process).
    static func startIfRequested(environment: AppEnvironment, arguments: [String]) {
        guard task == nil, let parsed = ASRDeviceBenchmarkRequest.parse(arguments) else { return }
        task = Task { @MainActor in
            await run(parsed, environment: environment)
        }
    }

    private static func run(
        _ parsed: Result<ASRDeviceBenchmarkRequest, ASRDeviceBenchmarkRequest.ParseError>, environment: AppEnvironment
    ) async {
        let identity = BuildIdentity.current
        let device = AppSpeechEngines.deviceDescription()
        let model = AppSpeechEngines.machineIdentifier()
        let request: ASRDeviceBenchmarkRequest
        switch parsed {
        case .success(let value):
            request = value
        case .failure(let error):
            let report = ASRDeviceBenchmarkReport(
                status: .failed, error: error.localizedDescription, requested: [], device: device, deviceModel: model,
                build: identity.summary, buildSHA: identity.commit, startedAt: Date(), finishedAt: Date())
            finish(report)
            return
        }
        await environment.launch()
        let items =
            Bundle.main.resourceURL.flatMap { try? ASRBenchmarkReferenceSet.load(from: $0) } ?? []
        let runner = ASRBenchmarkRunner(
            scheduler: environment.scheduler, normalizer: AVAudioNormalizer(),
            memory: { MemoryProbe.physicalFootprintBytes() }, availableMemory: { MemoryProbe.availableBytes() })
        let benchmark = ASRDeviceBenchmark(
            router: environment.speechRouter, runner: runner, items: items, device: device, deviceModel: model,
            build: identity.summary, buildSHA: identity.commit, availableMemory: { MemoryProbe.availableBytes() })
        write(benchmark.placeholder(for: request, startedAt: Date()))
        logger.notice(
            "bench_start engines=\(request.engines.map(\.rawValue).joined(separator: ","), privacy: .public) build=\(identity.summary, privacy: .public)"
        )
        let report = await DownloadKeepAlive.shared.withKeepAlive {
            await benchmark.run(
                request,
                log: { line in
                    // Engine names, timings and memory only.
                    Log.logger("device-benchmark").notice("\(line, privacy: .public)")
                },
                // Synchronous, inside `run`: every checkpoint lands before the final write below.
                checkpoint: { writeCheckpoint($0) })
        }
        if let run = report.run {
            try? await ASRBenchmarkStore.appDefault(paths: environment.paths).append(run)
            await environment.benchmark.refresh()
        }
        finish(report)
    }

    /// Writes the report and logs the one final line (stdout too, for `devicectl … --console`).
    private static func finish(_ report: ASRDeviceBenchmarkReport) {
        let line: String
        if write(report) {
            line =
                report.status == .completed
                ? "BENCH DONE \(resultURL.path)" : "BENCH FAIL \(report.error ?? "unknown error")"
        } else {
            line = "BENCH FAIL could not write \(resultURL.lastPathComponent)"
        }
        logger.notice("\(line, privacy: .public)")
        print(line)
    }

    /// A `running` report written while the benchmark runs (off the main actor, atomically).
    nonisolated private static func writeCheckpoint(_ report: ASRDeviceBenchmarkReport) {
        try? report.encoded().write(to: resultURL, options: .atomic)
    }

    /// Atomic, so the script never reads half a file.
    @discardableResult private static func write(_ report: ASRDeviceBenchmarkReport) -> Bool {
        do {
            try report.encoded().write(to: resultURL, options: .atomic)
            return true
        } catch {
            logger.error("bench_write_failed error_type=\(String(describing: type(of: error)), privacy: .public)")
            return false
        }
    }
}
#endif
