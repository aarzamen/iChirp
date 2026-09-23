import ChirpCore
import ChirpText
import Foundation
import Observation

/// Settings → Speech engines → Benchmark (M7 Step 6): pick engines, run them over the synthetic reference set and any
/// files the person adds, one at a time through the scheduler, and read or export the numbers.
///
/// A person's own files may be clinical (review M6): each is labelled "Your file 1", "Your file 2"… (its name is never
/// shown, stored or exported), copied under a neutral name, and every copy is deleted when the run ends and at launch
/// (`removeLeftoverImports`).
@MainActor @Observable public final class ASRBenchmarkViewModel {
    public struct EngineChoice: Identifiable, Equatable, Sendable {
        public var key: SpeechEngineVariantKey
        public var name: String
        /// Nil when it can run now; otherwise why not (not downloaded, not on this device).
        public var unavailableReason: String?
        public var id: SpeechEngineVariantKey { key }
        public var isReady: Bool { unavailableReason == nil }
    }

    public private(set) var engines: [EngineChoice] = []
    public var selected: Set<SpeechEngineVariantKey> = []
    public private(set) var referenceItems: [ASRBenchmarkItem] = []
    public private(set) var userItems: [ASRBenchmarkItem] = []
    public var includeReferenceSet = true
    public private(set) var isRunning = false
    public private(set) var progress: ASRBenchmarkProgress?
    /// Saved runs, oldest first (the newest is the one the screen shows).
    public private(set) var history: [ASRBenchmarkRun] = []
    public private(set) var lastError: String?

    public var latest: ASRBenchmarkRun? { history.last }
    public var canRun: Bool {
        !isRunning && !selectedReadyKeys.isEmpty
            && (includeReferenceSet && !referenceItems.isEmpty || !userItems.isEmpty)
    }

    @ObservationIgnored private let router: SpeechEngineRouter
    @ObservationIgnored private let runner: ASRBenchmarkRunner
    @ObservationIgnored private let store: ASRBenchmarkStore
    @ObservationIgnored private let referenceFolder: URL?
    @ObservationIgnored private let importFolder: URL
    @ObservationIgnored private let device: String
    @ObservationIgnored private let appBuild: String
    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private var hasChosen = false
    /// Numbers the neutral labels ("Your file 1"…); reset when the copies are deleted.
    @ObservationIgnored private var addedFileCount = 0

    /// - Parameters:
    ///   - referenceFolder: the bundled synthetic set (its manifest plus audio); nil when the build has none.
    ///   - importFolder: where added files are copied for the run (neutral names; deleted by `removeUserItem`, when a
    ///     run ends and by `removeLeftoverImports` at launch).
    public init(
        router: SpeechEngineRouter, runner: ASRBenchmarkRunner, store: ASRBenchmarkStore, referenceFolder: URL?,
        importFolder: URL, device: String, appBuild: String
    ) {
        self.router = router
        self.runner = runner
        self.store = store
        self.referenceFolder = referenceFolder
        self.importFolder = importFolder
        self.device = device
        self.appBuild = appBuild
    }

    // MARK: - Reading

    /// Engine readiness (never downloads), the reference set and saved runs.
    public func refresh() async {
        var choices: [EngineChoice] = []
        for registration in router.registrations {
            let row = SpeechEngineCapabilityRegistry.capabilitiesIfPresent(for: registration.key)
            let name = row?.displayName ?? registration.engine.descriptor.displayName
            choices.append(
                EngineChoice(
                    key: registration.key, name: name,
                    unavailableReason: await Self.unavailableReason(registration.engine, row: row)))
        }
        engines = choices
        if !hasChosen {
            selected = Set(choices.filter(\.isReady).map(\.key))
        }
        if referenceItems.isEmpty, let referenceFolder {
            referenceItems = (try? ASRBenchmarkReferenceSet.load(from: referenceFolder)) ?? []
        }
        history = await store.load()
    }

    public func toggle(_ key: SpeechEngineVariantKey) {
        hasChosen = true
        if selected.contains(key) { selected.remove(key) } else { selected.insert(key) }
    }

    public func dismissError() {
        lastError = nil
    }

    // MARK: - Files

    /// Copies files the person picked (security-scoped URLs from the file importer) into the import folder, under a
    /// neutral name, and labels each "Your file n": a file name can hold a patient's name.
    public func addFiles(_ urls: [URL]) {
        lastError = nil
        do {
            try FileManager.default.createDirectory(at: importFolder, withIntermediateDirectories: true)
            for url in urls {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let id = UUID().uuidString
                let ext = url.pathExtension
                let copy = importFolder.appendingPathComponent(ext.isEmpty ? id : "\(id).\(ext)")
                try FileManager.default.copyItem(at: url, to: copy)
                addedFileCount += 1
                userItems.append(
                    ASRBenchmarkItem(
                        id: id, title: "Your file \(addedFileCount)", audioURL: copy, referenceText: nil))
            }
        } catch {
            lastError = "Parakeet could not add that file. Details: \(error.localizedDescription)"
        }
    }

    /// Deletes copies an earlier launch left in the import folder (the list of added files is not kept). Call at
    /// launch.
    public func removeLeftoverImports() {
        guard userItems.isEmpty, !isRunning else { return }
        try? FileManager.default.removeItem(at: importFolder)
    }

    /// Forgets the added files and deletes their copies.
    private func removeImports() {
        userItems = []
        addedFileCount = 0
        try? FileManager.default.removeItem(at: importFolder)
    }

    public func removeUserItem(_ id: String) {
        guard let index = userItems.firstIndex(where: { $0.id == id }) else { return }
        try? FileManager.default.removeItem(at: userItems[index].audioURL)
        userItems.remove(at: index)
    }

    // MARK: - Running

    public func run() {
        guard canRun else { return }
        let engines = selectedReadyKeys.compactMap { key -> ASRBenchmarkEngine? in
            guard let engine = router.registeredEngine(for: key) else { return nil }
            return ASRBenchmarkEngine(key: key, name: name(for: key), engine: engine)
        }
        let items = (includeReferenceSet ? referenceItems : []) + userItems
        let runner = self.runner
        let store = self.store
        let started = Date()
        let device = self.device
        let appBuild = self.appBuild
        isRunning = true
        lastError = nil
        progress = ASRBenchmarkProgress(engineName: "", itemTitle: "", completed: 0, total: engines.count * items.count)
        // The view model lives as long as the app (AppEnvironment), so the run holds it strongly.
        runTask = Task {
            do {
                let results = try await runner.run(engines: engines, items: items) { value in
                    Task { @MainActor in if self.isRunning { self.progress = value } }
                }
                let run = ASRBenchmarkRun(startedAt: started, device: device, appBuild: appBuild, results: results)
                try await store.append(run)
                let saved = await store.load()
                self.finish(history: saved, error: nil)
            } catch is CancellationError {
                self.finish(history: nil, error: nil)
            } catch {
                self.finish(history: nil, error: "The benchmark stopped: \(error.localizedDescription)")
            }
        }
    }

    public func cancel() {
        runTask?.cancel()
    }

    /// Waits for a running benchmark (tests).
    public func waitForRun() async {
        await runTask?.value
    }

    /// The run ended (saved, failed or stopped): the copies of the person's files are deleted either way.
    private func finish(history: [ASRBenchmarkRun]?, error: String?) {
        if let history { self.history = history }
        lastError = error
        isRunning = false
        progress = nil
        runTask = nil
        removeImports()
    }

    // MARK: - Export

    /// Writes every saved run as CSV and JSON into `folder` (for the share sheet) and returns both files.
    public func exportFiles(to folder: URL) throws -> [URL] {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let csv = folder.appendingPathComponent("parakeet-asr-benchmark-\(stamp).csv")
        let json = folder.appendingPathComponent("parakeet-asr-benchmark-\(stamp).json")
        try Data(ASRBenchmarkExport.csv(history).utf8).write(to: csv, options: .atomic)
        try ASRBenchmarkExport.json(history).write(to: json, options: .atomic)
        return [csv, json]
    }

    // MARK: - Helpers

    private var selectedReadyKeys: [SpeechEngineVariantKey] {
        engines.filter { $0.isReady && selected.contains($0.key) }.map(\.key)
    }

    private func name(for key: SpeechEngineVariantKey) -> String {
        engines.first { $0.key == key }?.name ?? key.description
    }

    private static func unavailableReason(
        _ engine: any SpeechEngine, row: SpeechEngineCapabilities?
    ) async -> String? {
        if let row,
            let message = SpeechEngineCapabilityRegistry.memoryRequirementStatus(for: row)
                .insufficientMemoryMessage
        {
            return message
        }
        if let reporting = engine as? any SpeechEngineAvailabilityReporting,
            let reason = await reporting.unavailableReason()
        {
            return reason
        }
        if case .ready = await engine.assetStatus() { return nil }
        return "Not downloaded"
    }
}
