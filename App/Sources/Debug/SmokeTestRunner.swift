#if DEBUG
import ChirpCore
import ChirpFeatures
import Foundation
import Observation

/// DEBUG-only end-to-end check: transcribes the bundled synthetic two-voice sample through the real pipeline and
/// writes `Documents/smoke-result.json`, which `scripts/device_smoke.sh` reads.
///
/// Runs when the app is launched with `-ChirpSmoke transcribe-sample`, or from Settings → Diagnostics. It is the
/// one place allowed to download models without a tap on Download (logged), so a fresh install can be verified
/// from the command line.
@MainActor @Observable final class SmokeTestRunner {
    enum Trigger: String {
        case launchArgument = "launch_argument"
        case diagnostics
    }

    enum State: Equatable {
        case idle
        case running(step: String)
        case finished(SmokeResult)
    }

    /// The JSON written to `Documents/smoke-result.json`. Keys match what `scripts/device_smoke.sh` parses.
    struct SmokeResult: Codable, Equatable, Sendable {
        /// "running" while in progress, then "completed" or "failed".
        var status: String
        var text: String
        var wordCount: Int
        var speakerCount: Int
        /// Import + transcription of the sample, after the models are loaded.
        var elapsedMs: Int
        /// Loading the speech and speaker models into memory.
        var modelLoadMs: Int
        /// Peak `phys_footprint` over the whole run, sampled every 250 ms.
        var peakMemoryMB: Int
        /// `BuildIdentity.summary`; contains `ChirpBuildDateUTC`, which the script uses to reject stale files.
        var build: String
        /// Set when `status` is "failed".
        var error: String?
    }

    enum SmokeError: LocalizedError {
        case sampleMissing
        case noResult

        var errorDescription: String? {
            switch self {
            case .sampleMissing: "The bundled sample-two-voices.m4a is missing from the app."
            case .noResult: "The pipeline returned no row for the sample."
            }
        }
    }

    static let launchArgument = "-ChirpSmoke"
    static let transcribeSampleCommand = "transcribe-sample"
    static let resultFileName = "smoke-result.json"

    private(set) var state: State = .idle
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let logger = Log.logger("smoke")

    var isRunning: Bool {
        if case .running = state { return true }
        return false
    }

    /// True when `arguments` contain `-ChirpSmoke` immediately followed by `transcribe-sample`.
    static func isRequested(in arguments: [String]) -> Bool {
        guard let index = arguments.firstIndex(of: launchArgument), index + 1 < arguments.count else { return false }
        return arguments[index + 1] == transcribeSampleCommand
    }

    /// `Documents/smoke-result.json`.
    static var resultURL: URL {
        URL.documentsDirectory.appendingPathComponent(resultFileName, isDirectory: false)
    }

    /// Starts a run unless one is in flight. Unstructured on purpose: it must not end when a view disappears.
    func start(environment: AppEnvironment, reason: Trigger) {
        guard task == nil else { return }
        task = Task { [weak self] in
            await self?.run(environment: environment, reason: reason)
            self?.task = nil
        }
    }

    private func run(environment: AppEnvironment, reason: Trigger) async {
        let build = BuildIdentity.current.summary
        logger.notice("smoke_start trigger=\(reason.rawValue, privacy: .public) build=\(build, privacy: .public)")
        state = .running(step: "Starting")
        write(Self.placeholderResult(build: build))
        let peakSampler = MemoryProbe.samplePeakFootprint()
        var result: SmokeResult
        do {
            result = try await transcribeSample(environment: environment, build: build)
        } catch {
            let message = Formatting.message(for: error)
            logger.error(
                "smoke_failed error_type=\(String(describing: type(of: error)), privacy: .public) error=\(message, privacy: .public)"
            )
            result = Self.placeholderResult(build: build)
            result.status = "failed"
            result.error = message
        }
        peakSampler.cancel()
        result.peakMemoryMB = MemoryProbe.megabytes(await peakSampler.value)
        write(result)
        state = .finished(result)
        logger.notice(
            "smoke_done status=\(result.status, privacy: .public) words=\(result.wordCount, privacy: .public) speakers=\(result.speakerCount, privacy: .public) elapsed_ms=\(result.elapsedMs, privacy: .public) model_load_ms=\(result.modelLoadMs, privacy: .public) peak_mb=\(result.peakMemoryMB, privacy: .public)"
        )
    }

    private func transcribeSample(environment: AppEnvironment, build: String) async throws -> SmokeResult {
        await environment.launch()

        state = .running(step: "Checking models")
        try await ensureDownloaded(environment.speechEngine, name: "speech")
        try await ensureDownloaded(environment.diarizer, name: "diarizer")
        await environment.speechSettings.refresh()

        state = .running(step: "Loading models")
        let loadStart = ContinuousClock.now
        try await environment.speechEngine.prepare()
        try await environment.diarizer.prepare()
        let modelLoadMs = Self.milliseconds(since: loadStart)

        guard let sampleURL = Bundle.main.url(forResource: "sample-two-voices", withExtension: "m4a") else {
            throw SmokeError.sampleMissing
        }
        state = .running(step: "Transcribing sample")
        let runStart = ContinuousClock.now
        let id = try await environment.pipeline.importFile(from: sampleURL)
        let row = await environment.pipeline.process(id: id)
        // The pipeline reported progress into the job center; this run was not started there, so end it here.
        environment.jobCenter.finish(id)
        let elapsedMs = Self.milliseconds(since: runStart)
        guard let row else { throw SmokeError.noResult }

        let text = row.displayText
        let wordCount = row.wordTimestamps?.count ?? text.split(whereSeparator: \.isWhitespace).count
        return SmokeResult(
            status: row.status == .completed ? "completed" : "failed",
            text: text,
            wordCount: wordCount,
            speakerCount: row.speakerCount ?? 0,
            elapsedMs: elapsedMs,
            modelLoadMs: modelLoadMs,
            peakMemoryMB: 0,
            build: build,
            error: row.status == .completed ? nil : (row.errorMessage ?? "Row ended as \(row.status.rawValue)")
        )
    }

    /// Downloads the model when it is not on disk: the one download that happens without a tap (smoke mode only).
    private func ensureDownloaded(_ engine: any ModelAssetManaging, name: String) async throws {
        if case .ready = await engine.assetStatus() { return }
        logger.notice("smoke_auto_download model=\(name, privacy: .public) (smoke mode is the only auto-download)")
        state = .running(step: "Downloading \(name) model")
        try await DownloadKeepAlive.shared.withKeepAlive {
            try await engine.downloadAssets { _ in }
        }
        logger.notice("smoke_download_done model=\(name, privacy: .public)")
    }

    /// Writes the result atomically (a reader never sees half a file).
    private func write(_ result: SmokeResult) {
        do {
            try Self.encode(result).write(to: Self.resultURL, options: .atomic)
        } catch {
            logger.error("smoke_write_failed error_type=\(String(describing: type(of: error)), privacy: .public)")
        }
    }

    static func encode(_ result: SmokeResult) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(result)
    }

    static func placeholderResult(build: String) -> SmokeResult {
        SmokeResult(
            status: "running", text: "", wordCount: 0, speakerCount: 0, elapsedMs: 0, modelLoadMs: 0,
            peakMemoryMB: 0, build: build, error: nil)
    }

    private static func milliseconds(since start: ContinuousClock.Instant) -> Int {
        let elapsed = ContinuousClock.now - start
        return Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
    }
}
#endif
