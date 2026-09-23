#if DEBUG
import ChirpCore
import ChirpFeatures
import Foundation
import UIKit

/// DEBUG-only measurement of one small language model on this device (review I3): downloads the model when it is
/// missing, then writes a SOAP note of the invented `SyntheticNumberVisit` through the real `DeliverableService` path
/// (clinical, on device, no confirmation) and records `Documents/llm-smoke.json`, which `scripts/device_llm_smoke.sh`
/// reads.
///
/// Launch with `-ChirpLLMSmoke <model id>` (a catalog id or a unique prefix: `qwen3.5-2b`, `qwen3-4b`). Two runs: a
/// cold one (the model unloaded first; the first launch after an install also compiles llama.cpp's Metal library) and
/// a warm one (the model still loaded). Like the transcription smoke runner, this is the one place a model downloads
/// without a tap on Download (logged). The synthetic visit is one Library row with a fixed id, reused by every run;
/// each run adds its SOAP notes to it. Nothing here is a real patient.
@MainActor final class LLMSmokeRunner {
    /// `Documents/llm-smoke.json`. Keys match what `scripts/device_llm_smoke.sh` parses.
    struct Result: Codable, Equatable, Sendable {
        /// "running", "downloading", then "completed" or "failed".
        var status: String
        /// What the launch argument asked for.
        var requested: String
        /// `-ChirpLLMSmokeRun <token>`, so the script never mistakes an older file for this run's.
        var runID: String?
        /// The catalog id it resolved to (empty when it resolved to nothing).
        var modelID: String
        /// `BuildIdentity.summary`; contains `ChirpBuildDateUTC`, which the script uses to reject stale files.
        var build: String
        /// The hardware model, e.g. "iPhone16,1" (not a unique device identifier).
        var device: String
        var usesGPU: Bool
        var downloadFraction: Double?
        /// True when this run had to download the model first.
        var downloaded: Bool
        var downloadMs: Int?
        /// `os_proc_available_memory()` before the cold load; nil where the system does not report it.
        var availableMemoryBeforeMB: Int?
        /// The engine's estimate for the loaded model (weights, a full window's cache, buffers).
        var estimatedMemoryMB: Int
        var loadMs: Int?
        /// From the start of reading the prompt to the first generated token.
        var firstTokenMs: Int?
        /// From Start to the first streamed text, as the person sees it (includes the load).
        var timeToFirstTextMs: Int?
        var promptTokens: Int?
        var completionTokens: Int?
        var promptTokensPerSecond: Double?
        /// Generated tokens per second after the first one.
        var tokensPerSecond: Double?
        /// Start to stored note, cold run.
        var totalMs: Int?
        /// Peak `phys_footprint` over the cold run, sampled every 250 ms.
        var peakMemoryMB: Int
        var warm: WarmRun?
        /// Every required number verbatim in both notes and no number the visit never had (review I2).
        var numbersSurvived: Bool?
        var missingNumbers: [String]
        var unexpectedNumbers: [String]
        /// Set when `status` is "failed".
        var error: String?
    }

    /// The second run, with the model already loaded.
    struct WarmRun: Codable, Equatable, Sendable {
        var firstTokenMs: Int?
        var tokensPerSecond: Double?
        var totalMs: Int
        var numbersSurvived: Bool
    }

    enum RunnerError: LocalizedError {
        case unknownModel(String, known: [String])
        case runtimeMissing(String)
        case downloadFailed(String)
        case unavailable(String)
        case notRoutedOnDevice
        case noDocument

        var errorDescription: String? {
            switch self {
            case .unknownModel(let requested, let known):
                "No small model matches \"\(requested)\". Known: \(known.joined(separator: ", "))."
            case .runtimeMissing(let message): message
            case .downloadFailed(let message): "The download failed: \(message)"
            case .unavailable(let message): "The model cannot run now: \(message)"
            case .notRoutedOnDevice: "The SOAP note was not routed to this iPhone without a confirmation."
            case .noDocument: "The run ended without a stored note."
            }
        }
    }

    static let launchArgument = "-ChirpLLMSmoke"
    static let runArgument = "-ChirpLLMSmokeRun"
    static let resultFileName = "llm-smoke.json"
    /// The synthetic visit's fixed Library id, so repeated runs reuse one row.
    static let visitID = UUID(uuidString: "7C2D5E1A-4B3F-4E8D-9A61-2F0B6C8D4E17")!
    static let shared = LLMSmokeRunner()

    private var task: Task<Void, Never>?
    private let logger = Log.logger("llm-smoke")

    static var resultURL: URL {
        URL.documentsDirectory.appendingPathComponent(resultFileName, isDirectory: false)
    }

    /// The model asked for by `-ChirpLLMSmoke <id>`; an empty string when the flag has no id (the standard model).
    static func requestedModel(in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: launchArgument) else { return nil }
        let next = index + 1 < arguments.count ? arguments[index + 1] : ""
        return next.hasPrefix("-") ? "" : next
    }

    /// The token after `-ChirpLLMSmokeRun`, if any.
    static func runID(in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: runArgument), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    /// An exact catalog id, else the one option whose id starts with `requested` (case-insensitive); "" means the
    /// first standard-tier option.
    static func resolve(_ requested: String, in options: [LocalModelOption]) -> LocalModelOption? {
        let wanted = requested.lowercased()
        if wanted.isEmpty { return options.first { $0.tier == .standard } ?? options.first }
        if let exact = options.first(where: { $0.id.lowercased() == wanted }) { return exact }
        let matches = options.filter { $0.id.lowercased().hasPrefix(wanted) }
        return matches.count == 1 ? matches[0] : nil
    }

    /// Starts a run unless one is in flight. Unstructured on purpose: it must not end when a view disappears.
    func start(environment: AppEnvironment, requested: String, runID: String?) {
        guard task == nil else { return }
        task = Task { [weak self] in
            await self?.run(environment: environment, requested: requested, runID: runID)
            self?.task = nil
        }
    }

    private func run(environment: AppEnvironment, requested: String, runID: String?) async {
        // The model runs only while Parakeet is on screen: keep the phone from locking during the download and runs.
        let idleTimerWasDisabled = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = idleTimerWasDisabled }

        var result = Self.placeholder(requested: requested)
        result.runID = runID
        logger.notice(
            "llm_smoke_start requested=\(requested, privacy: .public) build=\(result.build, privacy: .public)")
        write(result)
        do {
            try await measure(environment: environment, result: &result)
            result.status = "completed"
        } catch {
            result.status = "failed"
            result.error = Formatting.message(for: error)
            logger.error(
                "llm_smoke_failed error_type=\(String(describing: type(of: error)), privacy: .public) error=\(result.error ?? "", privacy: .public)"
            )
        }
        write(result)
        logger.notice(
            "llm_smoke_done status=\(result.status, privacy: .public) model=\(result.modelID, privacy: .public) load_ms=\(result.loadMs ?? -1, privacy: .public) first_token_ms=\(result.firstTokenMs ?? -1, privacy: .public) tok_s=\(result.tokensPerSecond ?? -1, privacy: .public) peak_mb=\(result.peakMemoryMB, privacy: .public) numbers=\(result.numbersSurvived.map(String.init) ?? "n/a", privacy: .public)"
        )
    }

    private func measure(environment: AppEnvironment, result: inout Result) async throws {
        await environment.launch()
        let models = environment.languageModels
        if let problem = models.localModelRuntimeProblem { throw RunnerError.runtimeMissing(problem) }
        guard let option = Self.resolve(result.requested, in: models.localModels) else {
            throw RunnerError.unknownModel(result.requested, known: models.localModels.map(\.id))
        }
        result.modelID = option.id
        result.estimatedMemoryMB = MemoryProbe.megabytes(UInt64(max(option.memoryBytes, 0)))
        let local = AppLocalLanguageModels.debugShared.withLock { $0 }
        result.usesGPU = local?.debugUsesGPU ?? false
        write(result)

        try await ensureDownloaded(option, models: models, result: &result)

        let choice = LanguageModelChoice(localModel: option)
        let model = try models.makeModel(for: choice)
        if case .unavailable(let reason) = await model.availability() {
            throw RunnerError.unavailable(reason.message)
        }
        let visitID = try await insertVisitIfNeeded(environment: environment)
        let decision = try await environment.deliverables.route(
            transcriptionID: visitID, templateID: BuiltInTemplates.soapNote.id, model: model)
        guard case .allowed(let route) = decision, route.locality == .onDevice else {
            throw RunnerError.notRoutedOnDevice
        }

        // Cold: nothing loaded, so the engine's load time is this model's load on this phone.
        await local?.debugUnload()
        result.availableMemoryBeforeMB = MemoryProbe.availableBytes().map(MemoryProbe.megabytes)
        let peakSampler = MemoryProbe.samplePeakFootprint()
        let cold = try await generate(environment: environment, visitID: visitID, model: model)
        peakSampler.cancel()
        result.peakMemoryMB = MemoryProbe.megabytes(await peakSampler.value)
        let coldMetrics = await local?.debugLastRunMetrics()
        result.loadMs = coldMetrics?.loadSeconds.map(Self.milliseconds)
        result.firstTokenMs = coldMetrics?.firstTokenSeconds.map(Self.milliseconds)
        result.timeToFirstTextMs = cold.timeToFirstTextMs
        result.promptTokens = coldMetrics?.promptTokens
        result.completionTokens = coldMetrics?.completionTokens
        result.promptTokensPerSecond = coldMetrics.map { Self.rounded($0.promptTokensPerSecond) }
        result.tokensPerSecond = coldMetrics.map { Self.rounded($0.generationTokensPerSecond) }
        result.totalMs = cold.totalMs
        let coldReport = Self.numberReport(cold.text)

        // Warm: the model is still loaded.
        let warm = try await generate(environment: environment, visitID: visitID, model: model)
        let warmMetrics = await local?.debugLastRunMetrics()
        let warmReport = Self.numberReport(warm.text)
        result.warm = WarmRun(
            firstTokenMs: warmMetrics?.firstTokenSeconds.map(Self.milliseconds),
            tokensPerSecond: warmMetrics.map { Self.rounded($0.generationTokensPerSecond) }, totalMs: warm.totalMs,
            numbersSurvived: warmReport.passed)
        result.numbersSurvived = coldReport.passed && warmReport.passed
        result.missingNumbers = Array(Set(coldReport.missing + warmReport.missing)).sorted()
        result.unexpectedNumbers = Array(Set(coldReport.unexpected + warmReport.unexpected)).sorted()
    }

    /// Downloads through Settings' own path (status and checks as for a tap on Download), with progress in the file.
    private func ensureDownloaded(
        _ option: LocalModelOption, models: LanguageModelsViewModel, result: inout Result
    ) async throws {
        await models.refreshLocalModelStatus()
        if case .ready = models.localModelStatus[option.id] { return }
        logger.notice(
            "llm_smoke_auto_download model=\(option.id, privacy: .public) bytes=\(option.downloadBytes, privacy: .public) (smoke mode is the only auto-download)"
        )
        result.status = "downloading"
        result.downloaded = true
        result.downloadFraction = 0
        write(result)
        let started = ContinuousClock.now
        let snapshot = result
        let gate = ProgressGate()
        let ready = await DownloadKeepAlive.shared.withKeepAlive {
            await models.downloadLocalModel(id: option.id) { [weak self] fraction in
                guard gate.shouldWrite(fraction) else { return }
                var progress = snapshot
                progress.downloadFraction = fraction
                self?.write(progress)
            }
        }
        result.downloadMs = Self.milliseconds(since: started)
        result.downloadFraction = ready ? 1 : result.downloadFraction
        guard ready else {
            throw RunnerError.downloadFailed(models.localModelError ?? "the model is not ready after the download")
        }
        result.status = "running"
        write(result)
    }

    /// Writes download progress in 2% steps, never backwards.
    private final class ProgressGate {
        private var last = 0.0

        func shouldWrite(_ fraction: Double) -> Bool {
            guard fraction >= 1 || fraction - last >= 0.02 else { return false }
            last = fraction
            return true
        }
    }

    private func insertVisitIfNeeded(environment: AppEnvironment) async throws -> UUID {
        if try await environment.store.fetch(id: Self.visitID) != nil { return Self.visitID }
        var visit = SyntheticNumberVisit.transcription(fileName: "LLM smoke — synthetic visit (not a patient).m4a")
        visit.id = Self.visitID
        try await environment.store.insert(visit)
        return Self.visitID
    }

    private struct Generated {
        var text: String
        var timeToFirstTextMs: Int?
        var totalMs: Int
    }

    private func generate(environment: AppEnvironment, visitID: UUID, model: any LanguageModel) async throws
        -> Generated
    {
        let started = ContinuousClock.now
        var firstText: Int?
        var document: Deliverable?
        for try await event in environment.deliverables.generate(
            templateID: BuiltInTemplates.soapNote.id, transcriptionID: visitID, model: model)
        {
            switch event {
            case .routed(_, let overrideUsed) where overrideUsed:
                throw RunnerError.notRoutedOnDevice
            case .text:
                if firstText == nil { firstText = Self.milliseconds(since: started) }
            case .completed(let deliverable):
                document = deliverable
            default:
                break
            }
        }
        guard let document else { throw RunnerError.noDocument }
        return Generated(text: document.text, timeToFirstTextMs: firstText, totalMs: Self.milliseconds(since: started))
    }

    static func numberReport(_ note: String) -> NumberFidelityReport {
        NumberFidelity.check(
            note: note, required: SyntheticNumberVisit.requiredNumbers, source: SyntheticNumberVisit.text)
    }

    static func placeholder(requested: String) -> Result {
        Result(
            status: "running", requested: requested, runID: nil, modelID: "", build: BuildIdentity.current.summary,
            device: hardwareModel(), usesGPU: false, downloadFraction: nil, downloaded: false, downloadMs: nil,
            availableMemoryBeforeMB: nil, estimatedMemoryMB: 0, loadMs: nil, firstTokenMs: nil,
            timeToFirstTextMs: nil, promptTokens: nil, completionTokens: nil, promptTokensPerSecond: nil,
            tokensPerSecond: nil, totalMs: nil, peakMemoryMB: 0, warm: nil, numbersSurvived: nil, missingNumbers: [],
            unexpectedNumbers: [], error: nil)
    }

    /// Writes the result atomically (a reader never sees half a file).
    private func write(_ result: Result) {
        do {
            try Self.encode(result).write(to: Self.resultURL, options: .atomic)
        } catch {
            logger.error("llm_smoke_write_failed error_type=\(String(describing: type(of: error)), privacy: .public)")
        }
    }

    static func encode(_ result: Result) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(result)
    }

    private static func hardwareModel() -> String {
        #if targetEnvironment(simulator)
        return "Simulator"
        #else
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { buffer in
            String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
        }
        #endif
    }

    private static func milliseconds(_ seconds: Double) -> Int {
        Int((seconds * 1000).rounded())
    }

    private static func milliseconds(since start: ContinuousClock.Instant) -> Int {
        let elapsed = ContinuousClock.now - start
        return Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
    }

    private static func rounded(_ value: Double) -> Double {
        (value * 10).rounded() / 10
    }
}
#endif
