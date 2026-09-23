// Ported from MacParakeet (GPL-3.0): Sources/MacParakeetCore/SpeechEnginePreference.swift @ bbae9e0e
// (live and final transcription routes, `MeetingSpeechPlan`) and Sources/MacParakeetCore/STT/STTScheduler.swift
// @ bbae9e0e (`beginSpeechEngineSession` / `endSpeechEngineSession` leases that block engine switches).
// Changes: iChirp's engines are all built at launch, so a "switch" only changes which instance a route resolves to.
// The router is itself a `SpeechEngine` and `LiveSpeechSessionProviding` (final and live route), so the pipeline,
// dictation and meetings keep taking `any SpeechEngine`. They take their route's engine once, when a job is queued
// (`SpeechRouting.resolve`), instead of the scheduler snapshotting a runtime selection. The final route covers
// every kept transcript, including a dictation's final pass (spec/06), where upstream routed dictation to the live
// engine. A live engine without its own live mode previews through `TailWindowPreviewSession` over a temporary WAV.

import Foundation

/// Which job a speech engine serves (upstream ADR-016 / ADR-026).
public enum SpeechRoute: String, Sendable, Codable, CaseIterable {
    /// Display-only text while someone speaks: the dictation preview and a meeting's live text.
    case live
    /// Every kept transcript: imported files, a dictation's final pass, a meeting's final pass.
    case final
}

/// The saved engine choice for each route.
public struct SpeechRouteSelection: Codable, Sendable, Equatable {
    public var live: SpeechEngineVariantKey
    public var final: SpeechEngineVariantKey

    /// Parakeet on both routes.
    public static let `default` = SpeechRouteSelection(
        live: SpeechEngineCapabilityRegistry.defaultKey, final: SpeechEngineCapabilityRegistry.defaultKey)

    public init(live: SpeechEngineVariantKey, final: SpeechEngineVariantKey) {
        self.live = live
        self.final = final
    }

    public subscript(route: SpeechRoute) -> SpeechEngineVariantKey {
        get { route == .live ? live : final }
        set {
            if route == .live { live = newValue } else { final = newValue }
        }
    }

    /// Forgiving: a missing or unreadable route keeps the default.
    public init(from decoder: any Decoder) throws {
        self = .default
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let value = try? container.decodeIfPresent(SpeechEngineVariantKey.self, forKey: .live) { live = value }
        if let value = try? container.decodeIfPresent(SpeechEngineVariantKey.self, forKey: .final) { final = value }
    }
}

/// A meeting's hold on the current routes: while any lease is out, route changes are refused.
public struct SpeechEngineLease: Sendable, Hashable {
    public let id: UUID
    public let selection: SpeechRouteSelection

    public init(id: UUID = UUID(), selection: SpeechRouteSelection) {
        self.id = id
        self.selection = selection
    }

    public static func == (lhs: SpeechEngineLease, rhs: SpeechEngineLease) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Why a route change was refused.
public enum SpeechRouteError: Error, Equatable, LocalizedError {
    case meetingInProgress
    case engineNotInBuild(String)
    case noLivePreview(String)

    public var errorDescription: String? {
        switch self {
        case .meetingInProgress:
            return "A meeting is using the speech engines. Change them after it finishes."
        case .engineNotInBuild(let name):
            return "\(name) isn’t part of this build."
        case .noLivePreview(let name):
            return "\(name) can’t show live text."
        }
    }
}

/// A speech engine that stands for other engines, one per route.
public protocol SpeechEngineRouting: SpeechEngine, LiveSpeechSessionProviding {
    /// The engine `route` resolves to right now.
    func engine(for route: SpeechRoute) -> any SpeechEngine
    /// Pins the current routes until `endLease` (a meeting, from start to its final pass).
    func beginLease() -> SpeechEngineLease
    func endLease(_ lease: SpeechEngineLease)
}

/// How consumers take a route's engine without knowing whether they were given a router.
public enum SpeechRouting {
    /// A router's current engine for `route`; any other engine is itself. Call it once, when the job is queued, and
    /// use the result for the whole job (routing check, `prepare`, `transcribe`, the stored `engine` id).
    public static func resolve(_ engine: any SpeechEngine, for route: SpeechRoute) -> any SpeechEngine {
        (engine as? any SpeechEngineRouting)?.engine(for: route) ?? engine
    }

    /// A lease when `engine` is a router, else nil.
    public static func beginLease(on engine: any SpeechEngine) -> SpeechEngineLease? {
        (engine as? any SpeechEngineRouting)?.beginLease()
    }

    public static func endLease(_ lease: SpeechEngineLease?, on engine: any SpeechEngine) {
        guard let lease else { return }
        (engine as? any SpeechEngineRouting)?.endLease(lease)
    }
}

/// Routes speech work to the engine chosen for each route. Built once at launch with every engine instance of the
/// build; the selection is persisted by the caller through `onSelectionChange`.
///
/// As a `SpeechEngine` it is the **final** route (descriptor, assets, `prepare`, `transcribe`); as a
/// `LiveSpeechSessionProviding` it is the **live** route.
public final class SpeechEngineRouter: SpeechEngineRouting, @unchecked Sendable {
    // @unchecked Sendable: `current` and `leases` are only touched while `lock` is held; the rest is immutable.

    /// One engine instance and the registry key it answers to.
    public struct Registration: Sendable {
        public let key: SpeechEngineVariantKey
        public let engine: any SpeechEngine

        public init(key: SpeechEngineVariantKey, engine: any SpeechEngine) {
            self.key = key
            self.engine = engine
        }
    }

    public let registrations: [Registration]
    private let lock = NSLock()
    private var current: SpeechRouteSelection
    private var leases: [UUID: SpeechEngineLease] = [:]
    private let onSelectionChange: @Sendable (SpeechRouteSelection) -> Void
    private let temporaryDirectory: URL

    /// - Parameters:
    ///   - engines: every speech engine instance in this build; the first one is the fallback for a saved choice
    ///     that is not in the build (put Parakeet first).
    ///   - selection: the saved choice; a route naming an engine that is not registered falls back to the first.
    public init(
        engines: [Registration],
        selection: SpeechRouteSelection = .default,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        onSelectionChange: @escaping @Sendable (SpeechRouteSelection) -> Void = { _ in }
    ) {
        precondition(!engines.isEmpty, "SpeechEngineRouter needs at least one engine")
        self.registrations = engines
        self.onSelectionChange = onSelectionChange
        self.temporaryDirectory = temporaryDirectory
        var resolved = selection
        for route in SpeechRoute.allCases where Self.registration(matching: selection[route], in: engines) == nil {
            resolved[route] = engines[0].key
        }
        self.current = resolved
    }

    // MARK: - Selection

    public var selection: SpeechRouteSelection {
        lock.withLock { current }
    }

    public var activeLeaseCount: Int {
        lock.withLock { leases.count }
    }

    public var registeredKeys: [SpeechEngineVariantKey] {
        registrations.map(\.key)
    }

    /// The registered instance for `key`: the exact key, or the engine's instance when either side leaves the
    /// variant open (Parakeet runs whichever variant Settings chose at launch).
    public func registeredEngine(for key: SpeechEngineVariantKey) -> (any SpeechEngine)? {
        Self.registration(matching: key, in: registrations)?.engine
    }

    /// The registered key that `key` resolves to.
    public func registeredKey(for key: SpeechEngineVariantKey) -> SpeechEngineVariantKey? {
        Self.registration(matching: key, in: registrations)?.key
    }

    /// Chooses `key` for `route`. Refused while a meeting holds a lease, for an engine not in this build, and for
    /// the live route when the registry says the engine cannot preview.
    public func select(_ key: SpeechEngineVariantKey, for route: SpeechRoute) throws {
        guard let registration = Self.registration(matching: key, in: registrations) else {
            throw SpeechRouteError.engineNotInBuild(Self.name(for: key))
        }
        if route == .live, let row = SpeechEngineCapabilityRegistry.capabilitiesIfPresent(for: registration.key),
            !row.supportsLivePreview
        {
            throw SpeechRouteError.noLivePreview(row.displayName)
        }
        let changed: SpeechRouteSelection? = try lock.withLock {
            guard leases.isEmpty else { throw SpeechRouteError.meetingInProgress }
            guard current[route] != registration.key else { return nil }
            current[route] = registration.key
            return current
        }
        if let changed { onSelectionChange(changed) }
    }

    // MARK: - SpeechEngineRouting

    public func engine(for route: SpeechRoute) -> any SpeechEngine {
        let key = selection[route]
        return Self.registration(matching: key, in: registrations)?.engine ?? registrations[0].engine
    }

    public func beginLease() -> SpeechEngineLease {
        lock.withLock {
            let lease = SpeechEngineLease(selection: current)
            leases[lease.id] = lease
            return lease
        }
    }

    public func endLease(_ lease: SpeechEngineLease) {
        _ = lock.withLock { leases.removeValue(forKey: lease.id) }
    }

    // MARK: - SpeechEngine (the final route)

    public var descriptor: EngineDescriptor {
        engine(for: .final).descriptor
    }

    public func assetStatus() async -> ModelAssetStatus {
        await engine(for: .final).assetStatus()
    }

    public func downloadAssets(progress: @escaping @Sendable (Double) -> Void) async throws {
        try await engine(for: .final).downloadAssets(progress: progress)
    }

    public func deleteAssets() async throws {
        try await engine(for: .final).deleteAssets()
    }

    public func prepare() async throws {
        try await engine(for: .final).prepare()
    }

    public func transcribe(
        fileAt url: URL,
        options: SpeechTranscriptionOptions,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> SpeechResult {
        try await engine(for: .final).transcribe(fileAt: url, options: options, progress: progress)
    }

    // MARK: - LiveSpeechSessionProviding (the live route)

    /// The live engine's own session when it has one; otherwise a tail-window preview that writes each window to a
    /// temporary WAV (deleted after the pass) and transcribes it. Nil while the live engine's model is not on disk;
    /// never downloads.
    public func makeLiveSession(
        scheduler: SpeechJobScheduler, options: SpeechTranscriptionOptions
    ) async -> (any LiveSpeechSession)? {
        let live = engine(for: .live)
        if let provider = live as? any LiveSpeechSessionProviding {
            return await provider.makeLiveSession(scheduler: scheduler, options: options)
        }
        guard case .ready = await live.assetStatus() else { return nil }
        let directory = temporaryDirectory
        let passOptions = SpeechTranscriptionOptions(languageHint: options.languageHint, purpose: .dictation)
        let session = TailWindowPreviewSession(scheduler: scheduler) { window in
            let url = directory.appendingPathComponent("live-preview-\(UUID().uuidString).wav", isDirectory: false)
            try SpeechWAVFile.write(window, to: url)
            defer { try? FileManager.default.removeItem(at: url) }
            try await live.prepare()
            return try await live.transcribe(fileAt: url, options: passOptions, progress: { _ in }).text
        }
        await session.startTicking()
        return session
    }

    // MARK: - Helpers

    private static func registration(
        matching key: SpeechEngineVariantKey, in registrations: [Registration]
    ) -> Registration? {
        registrations.first { $0.key == key } ?? registrations.first { $0.key.matches(key) }
    }

    private static func name(for key: SpeechEngineVariantKey) -> String {
        SpeechEngineCapabilityRegistry.capabilitiesIfPresent(for: key)?.displayName ?? key.description
    }
}
