import ChirpCore
import Foundation
import Observation

/// Settings → Structure models → Eval: runs the STUB and Needle over the synthetic cases, keeps each engine's report,
/// saves it to the ledger and exports it (JSON, "Copy for LLM" Markdown).
@MainActor @Observable public final class StructureEvalViewModel {
    public enum Phase: Equatable {
        case idle
        case running(engine: String, done: Int, total: Int)
        case failed(String)
    }

    public private(set) var phase: Phase = .idle
    /// The latest report per engine id.
    public private(set) var reports: [String: StructureEvalReport] = [:]
    public private(set) var history: [StructuredEvalRun] = []
    /// Why Needle cannot run now (nil when it can).
    public private(set) var needleUnavailableReason: String?
    public var normalizerOn = true

    @ObservationIgnored private let engines: StructureEngines
    @ObservationIgnored private let settings: any StructureSettingsStoring
    @ObservationIgnored private let store: any StructuredResultStoring
    @ObservationIgnored private let appBuild: String
    @ObservationIgnored private let runtime: String?

    public init(
        engines: StructureEngines, settings: any StructureSettingsStoring, store: any StructuredResultStoring,
        appBuild: String, runtime: String?
    ) {
        self.engines = engines
        self.settings = settings
        self.store = store
        self.appBuild = appBuild
        self.runtime = runtime
    }

    public func refresh() async {
        switch await engines.needleAvailability() {
        case .ready: needleUnavailableReason = engines.needle == nil ? "Needle is not in this build." : nil
        case .unavailable(let reason): needleUnavailableReason = reason
        }
        history = (try? await store.evalRuns()) ?? []
    }

    public var isRunning: Bool {
        if case .running = phase { return true }
        return false
    }

    public func runStub() async {
        await run(engine: engines.stub)
    }

    public func runNeedle() async {
        await refresh()
        guard needleUnavailableReason == nil, let needle = engines.needle else {
            phase = .failed(needleUnavailableReason ?? "Needle is not in this build.")
            return
        }
        await run(engine: needle)
    }

    public func report(for engineID: String) -> StructureEvalReport? { reports[engineID] }

    private func run(engine: any StructureModel) async {
        let soap: SOAPEvalSet
        let commands: CommandEvalSet
        do {
            soap = try SOAPEvalSet.bundled()
            commands = try CommandEvalSet.bundled()
        } catch {
            phase = .failed("The eval cases are missing from this build.")
            return
        }
        let name = engine.descriptor.displayName
        phase = .running(engine: name, done: 0, total: 0)
        let gate = settings.load().gate
        let runner = StructureEvalRunner(engine: engine, gate: gate, normalizer: normalizerOn)
        let result = await runner.run(soap: soap, commands: commands) { done, total in
            Task { @MainActor [weak self] in
                guard let self, case .running = self.phase else { return }
                self.phase = .running(engine: name, done: done, total: total)
            }
        }
        let isStub = engine.descriptor.id == StubStructureModel.engineID
        let report = StructureEvalReport(
            createdAt: Date(), appBuild: appBuild, engineID: engine.descriptor.id, engineName: name, isStub: isStub,
            modelSHA256: result.modelSHA256, runtime: isStub ? nil : runtime, actThreshold: gate.act,
            provisionalThreshold: gate.provisional, normalizer: normalizerOn, soap: result.soap,
            commands: result.commands)
        reports[engine.descriptor.id] = report
        if let json = try? report.jsonData(), let text = String(data: json, encoding: .utf8) {
            try? await store.saveEvalRun(
                StructuredEvalRun(
                    engineID: report.engineID, modelSHA256: report.modelSHA256, catalogVersion: report.catalogVersion,
                    caseCount: soap.cases.count + commands.utterances.count,
                    toolShapeAccuracy: report.soap.toolShapeAccuracy, argumentAccuracy: report.soap.argumentAccuracy,
                    numericHardFails: report.soap.numericHardFails, reportJSON: text))
        }
        history = (try? await store.evalRuns()) ?? history
        phase = .idle
    }

    /// Writes a report's JSON to a temporary file for the share sheet.
    public func exportFile(for engineID: String) throws -> URL? {
        guard let report = reports[engineID] else { return nil }
        let stamp = ISO8601DateFormatter().string(from: report.createdAt).replacingOccurrences(of: ":", with: "-")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "parakeet-structure-eval-\(engineID)-\(stamp).json")
        try report.jsonData().write(to: url, options: .atomic)
        return url
    }
}
