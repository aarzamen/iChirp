import ChirpCore
import Foundation
import Observation

/// Settings → Speech engines (M7): the live and final route pickers and one row per engine build, with its size,
/// capabilities, model state and Download / Delete.
///
/// Only engines whose model is on disk can be chosen; a downloadable one shows Download. An engine that cannot run
/// here (not in this build, not on this device, or above the memory budget) is listed with the reason and cannot be
/// chosen or downloaded. Route changes go through `SpeechEngineRouter.select`, which refuses them during a meeting.
@MainActor @Observable public final class SpeechEnginesViewModel {
    /// What a row can do right now.
    public enum Availability: Equatable, Sendable {
        case ready
        case downloadable
        case downloading(fraction: Double)
        /// Cannot be chosen or downloaded here; the reason is shown.
        case unavailable(String)
    }

    public struct Row: Identifiable, Equatable, Sendable {
        public let capabilities: SpeechEngineCapabilities
        public let status: ModelAssetStatus
        public let availability: Availability

        public var id: SpeechEngineVariantKey { capabilities.key }
        public var isReady: Bool { availability == .ready }

        /// The last download failure, when the model can still be downloaded again.
        public var failureMessage: String? {
            if case .failed(let message) = status, availability == .downloadable { return message }
            return nil
        }
    }

    public private(set) var rows: [Row] = []
    public private(set) var selection: SpeechRouteSelection
    /// The last refused route change or failed model action; cleared by the next action.
    public private(set) var lastError: String?

    @ObservationIgnored private let router: SpeechEngineRouter
    @ObservationIgnored private let physicalMemoryBytes: UInt64
    @ObservationIgnored private let budgetBytes: Int64
    @ObservationIgnored private var activeDownloads: Set<SpeechEngineVariantKey> = []

    public init(
        router: SpeechEngineRouter,
        physicalMemoryBytes: UInt64 = ProcessInfo.processInfo.physicalMemory,
        budgetBytes: Int64 = SpeechEngineCapabilityRegistry.memoryBudgetBytes
    ) {
        self.router = router
        self.physicalMemoryBytes = physicalMemoryBytes
        self.budgetBytes = budgetBytes
        self.selection = router.selection
        self.rows = Self.catalog(router: router).map {
            Row(capabilities: $0.capabilities, status: .notDownloaded, availability: .unavailable("Checking…"))
        }
    }

    // MARK: - Reading

    /// Re-reads every registered engine's model state (never downloads).
    public func refresh() async {
        selection = router.selection
        var fresh: [Row] = []
        for entry in Self.catalog(router: router) {
            fresh.append(await makeRow(entry))
        }
        rows = fresh
    }

    /// Rows that can be chosen for `route`: ready (and able to preview, for live), plus the current choice so the
    /// picker always shows it.
    public func choices(for route: SpeechRoute) -> [Row] {
        let current = router.registeredKey(for: selection[route])
        return rows.filter { row in
            if row.id == current { return true }
            guard row.isReady else { return false }
            return route == .final || row.capabilities.supportsLivePreview
        }
    }

    /// The row a route resolves to now.
    public func row(for route: SpeechRoute) -> Row? {
        let key = router.registeredKey(for: selection[route])
        return rows.first { $0.id == key }
    }

    public func dismissError() {
        lastError = nil
    }

    // MARK: - Choosing

    /// Chooses `key` for `route`; a refusal (a meeting is running, not ready, cannot preview) lands in `lastError`.
    public func select(_ key: SpeechEngineVariantKey, for route: SpeechRoute) {
        lastError = nil
        guard let row = rows.first(where: { $0.id == key }), row.isReady else {
            lastError = "Download this engine’s model before choosing it."
            return
        }
        do {
            try router.select(key, for: route)
        } catch {
            lastError = error.localizedDescription
        }
        selection = router.selection
    }

    // MARK: - Models

    /// Downloads `key`'s model. `onProgress` also receives each fraction on the main actor. Returns whether it is ready.
    @discardableResult public func download(
        _ key: SpeechEngineVariantKey, onProgress: (@MainActor (Double) -> Void)? = nil
    ) async -> Bool {
        guard let entry = Self.catalog(router: router).first(where: { $0.capabilities.key == key }),
            let engine = entry.engine
        else { return false }
        lastError = nil
        activeDownloads.insert(key)
        replace(key, status: .downloading(fraction: 0))
        do {
            try await engine.downloadAssets { [weak self] fraction in
                Task { @MainActor [weak self] in
                    guard let self, self.activeDownloads.contains(key) else { return }
                    self.replace(key, status: .downloading(fraction: fraction))
                    onProgress?(fraction)
                }
            }
        } catch {
            lastError = error.localizedDescription
        }
        activeDownloads.remove(key)
        let row = await makeRow(entry)
        replace(row)
        return row.isReady
    }

    /// Deletes `key`'s model files (the screen asks first). For a system-managed model this releases the app's claim.
    public func delete(_ key: SpeechEngineVariantKey) async {
        guard let entry = Self.catalog(router: router).first(where: { $0.capabilities.key == key }),
            let engine = entry.engine
        else { return }
        lastError = nil
        do {
            try await engine.deleteAssets()
        } catch {
            lastError = error.localizedDescription
        }
        replace(await makeRow(entry))
    }

    // MARK: - Catalog

    private struct Entry {
        let capabilities: SpeechEngineCapabilities
        let engine: (any SpeechEngine)?
    }

    /// Every registry row this screen lists: each registered instance's row, then the rows with no instance in this
    /// build (listed with the reason). A Parakeet variant other than the running one is left out: Settings → Speech
    /// → Model version chooses it.
    private static func catalog(router: SpeechEngineRouter) -> [Entry] {
        var entries: [Entry] = []
        var listedEngines: Set<String> = []
        for registration in router.registrations {
            let row =
                SpeechEngineCapabilityRegistry.capabilitiesIfPresent(for: registration.key)
                ?? Self.fallbackCapabilities(for: registration)
            entries.append(Entry(capabilities: row, engine: registration.engine))
            if registration.key.engineID == SpeechEngineCapabilityRegistry.parakeetEngineID {
                listedEngines.insert(registration.key.engineID)
            }
        }
        let registered = Set(router.registrations.map(\.key))
        for row in SpeechEngineCapabilityRegistry.all
        where !registered.contains(row.key) && !listedEngines.contains(row.key.engineID) {
            entries.append(Entry(capabilities: row, engine: nil))
        }
        return entries
    }

    private static func fallbackCapabilities(for registration: SpeechEngineRouter.Registration)
        -> SpeechEngineCapabilities
    {
        let descriptor = registration.engine.descriptor
        return SpeechEngineCapabilities(
            key: registration.key, displayName: descriptor.displayName, providerSummary: descriptor.provider,
            supportsNativeLiveDictation: false, supportsTailPreview: true,
            providesWordTimestamps: descriptor.providesWordTimestamps,
            supportedLanguages: .automatic(supportedLanguageCodes: descriptor.supportedLanguages),
            supportsCustomVocabulary: false,
            modelLifecycle: SpeechEngineModelLifecycle(
                modelName: descriptor.displayName, approximateDownloadBytes: descriptor.approximateDownloadBytes,
                approximateRuntimeMemoryBytes: nil),
            runsOn: "On this iPhone")
    }

    private func makeRow(_ entry: Entry) async -> Row {
        let memory = SpeechEngineCapabilityRegistry.memoryRequirementStatus(
            for: entry.capabilities, physicalMemoryBytes: physicalMemoryBytes, budgetBytes: budgetBytes)
        guard let engine = entry.engine else {
            let reason = memory.insufficientMemoryMessage ?? "Not part of this build."
            return Row(capabilities: entry.capabilities, status: .notDownloaded, availability: .unavailable(reason))
        }
        if let reason = memory.insufficientMemoryMessage {
            return Row(capabilities: entry.capabilities, status: .notDownloaded, availability: .unavailable(reason))
        }
        if let reporting = engine as? any SpeechEngineAvailabilityReporting,
            let reason = await reporting.unavailableReason()
        {
            return Row(capabilities: entry.capabilities, status: .notDownloaded, availability: .unavailable(reason))
        }
        let status = await engine.assetStatus()
        return Row(capabilities: entry.capabilities, status: status, availability: Self.availability(for: status))
    }

    private static func availability(for status: ModelAssetStatus) -> Availability {
        switch status {
        case .ready: .ready
        case .downloading(let fraction): .downloading(fraction: fraction)
        case .notDownloaded, .failed: .downloadable
        }
    }

    private func replace(_ key: SpeechEngineVariantKey, status: ModelAssetStatus) {
        guard let index = rows.firstIndex(where: { $0.id == key }) else { return }
        let old = rows[index]
        rows[index] = Row(capabilities: old.capabilities, status: status, availability: Self.availability(for: status))
    }

    private func replace(_ row: Row) {
        guard let index = rows.firstIndex(where: { $0.id == row.id }) else { return }
        rows[index] = row
    }
}
