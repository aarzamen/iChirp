import ChirpCore
import Foundation
import Observation

/// Settings → Speech engines (M7): the live and final route pickers and one row per engine build, with its size,
/// capabilities, model state and Download / Delete.
///
/// Only engines whose model is on disk can be chosen; a downloadable one shows Download. An engine that cannot run
/// here (not in this build, not on this device, or above the memory budget) is listed with the reason and cannot be
/// chosen or downloaded. Route changes go through `SpeechEngineRouter.select`, which refuses them during a meeting.
///
/// Review fixes (fix/asr-review, fix/asr-minors):
/// - **Delete of a routed engine (I2, N3).** Refused while a meeting holds the routes. Otherwise the delete is asked
///   for first; only once the engine agrees do its routes move back to Parakeet, and `lastNotice` says so (the
///   dialog says it beforehand, `routesUsing`). An engine that refuses because a job is using it (N3) leaves the
///   routes untouched and says so, never moving them and then contradicting itself.
/// - **The delete notice names the right engine (N2).** Read from the fallback's own row, not `row(for: .final)`,
///   which is wrong when the delete only moved Live text.
/// - **Memory (I3).** After a route change, the engine that is on no route any more is unloaded
///   (`SpeechEngineRouter.releaseUnroutedModels`); a Transcripts choice too big to share memory with the live engine
///   moves live text to it as well, and `lastNotice` says so.
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
    /// Something the app changed for the person as a result of their action (a route moved back to Parakeet);
    /// cleared by the next action.
    public private(set) var lastNotice: String?

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
        lastNotice = nil
    }

    /// The routes that use `key` now, in Settings order (live text, then transcripts): what a delete would change.
    public func routesUsing(_ key: SpeechEngineVariantKey) -> [SpeechRoute] {
        guard let registered = router.registeredKey(for: key) else { return [] }
        return SpeechRoute.allCases.filter { router.registeredKey(for: router.selection[$0]) == registered }
    }

    /// "Live text", "Transcripts" or "Live text and Transcripts".
    public static func routeNames(_ routes: [SpeechRoute]) -> String {
        routes.map { $0 == .live ? "Live text" : "Transcripts" }.joined(separator: " and ")
    }

    // MARK: - Choosing

    /// Chooses `key` for `route`; a refusal (a meeting is running, not ready, cannot preview, too much memory with the
    /// other route's engine) lands in `lastError`. Then releases the model of the engine that left both routes.
    public func select(_ key: SpeechEngineVariantKey, for route: SpeechRoute) async {
        lastError = nil
        lastNotice = nil
        guard let row = rows.first(where: { $0.id == key }), row.isReady else {
            lastError = "Download this engine’s model before choosing it."
            return
        }
        let changed: Set<SpeechRoute>
        do {
            changed = try router.select(key, for: route)
        } catch {
            lastError = error.localizedDescription
            return
        }
        selection = router.selection
        if route == .final, changed.contains(.live) {
            lastNotice =
                "Live text uses \(row.capabilities.displayName) too: a second engine beside it would need more "
                + "memory than this iPhone’s model budget."
        }
        guard !changed.isEmpty else { return }
        await router.releaseUnroutedModels()
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
    ///
    /// Review I2: an engine a route uses is never deleted while a meeting holds the routes. Review N3: the engine
    /// itself can still refuse (a running job holds it, e.g. WhisperKit's `busy`), so the delete is asked for first;
    /// only once it succeeds do the routes that used it move back to Parakeet, and `lastNotice` says so — never the
    /// other way around, which could move the routes and then have the delete refuse, leaving a notice that
    /// contradicts the alert right above it. (Deleting Parakeet itself leaves the routes: it is the fallback, and a
    /// job then says to download it.)
    public func delete(_ key: SpeechEngineVariantKey) async {
        guard let entry = Self.catalog(router: router).first(where: { $0.capabilities.key == key }),
            let engine = entry.engine
        else { return }
        lastError = nil
        lastNotice = nil
        let name = entry.capabilities.displayName
        let routes = routesUsing(key)
        if !routes.isEmpty {
            // Checked before any suspension: a meeting cannot start in between (both on the main actor).
            guard router.activeLeaseCount == 0 else {
                lastError = "\(name) is in use by a meeting. Delete it after the meeting finishes."
                return
            }
        }
        do {
            try await engine.deleteAssets()
        } catch {
            // Review N3: e.g. "Whisper Base is in use by a running job. Delete it after the job finishes." The
            // routes must not have moved: they still point at the model that is still there.
            lastError = error.localizedDescription
            return
        }
        replace(await makeRow(entry))
        guard !routes.isEmpty else { return }
        let fallback = SpeechEngineCapabilityRegistry.defaultKey
        guard router.registeredKey(for: fallback) != router.registeredKey(for: key) else { return }
        do {
            // Transcripts first: a final choice may move live text along with it (memory), never the reverse.
            for route in [SpeechRoute.final, .live] where routes.contains(route) {
                try router.select(fallback, for: route)
            }
        } catch {
            // The files are already gone; only a meeting that started in the instant after the delete's await
            // (the lease check above ran before it) could refuse this. Rare, and still honest: a job on the
            // untouched route now names this engine as missing, with Retry after switching in Settings.
            lastError = error.localizedDescription
            return
        }
        selection = router.selection
        // Review N2: the fallback's own row, not `row(for: .final)` — a delete that only moves Live text (Transcripts
        // already used something else) leaves `.final` unchanged, so that route's name is the wrong one to read.
        let fallbackKey = router.registeredKey(for: fallback)
        let fallbackName = rows.first(where: { $0.id == fallbackKey })?.capabilities.displayName ?? "Parakeet"
        lastNotice =
            "\(name) was deleted, so \(Self.routeNames(routes)) use\(routes.count == 1 ? "s" : "") "
            + "\(fallbackName) now."
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
