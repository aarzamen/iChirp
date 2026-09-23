// Ported from MacParakeet (GPL-3.0): Sources/MacParakeetCore/STT/SpeechEngineCapabilities.swift @ bbae9e0e
// Changes: rows are keyed by the stable `EngineDescriptor.id` plus a variant string instead of upstream's engine
// enum (ChirpCore cannot import engine targets); telemetry identity dropped; the memory floor is joined by a
// runtime-memory estimate checked against the iPhone memory budget (spec/06), and rows name where they run and
// whether iOS manages the download. Rows: Parakeet v3/v2, Apple SpeechTranscriber, WhisperKit base / large-v3 turbo,
// and WhisperKit large-v3 (listed, over the budget).

import Foundation

/// One selectable build of a speech engine: the stable engine id plus the variant (nil = the engine's only build,
/// or "whichever variant this engine instance runs", as for Parakeet, whose variant is chosen in Settings).
public struct SpeechEngineVariantKey: Hashable, Sendable, Codable, CustomStringConvertible {
    public var engineID: String
    public var variant: String?

    public init(engineID: String, variant: String? = nil) {
        self.engineID = engineID
        self.variant = variant
    }

    public var description: String {
        variant.map { "\(engineID):\($0)" } ?? engineID
    }

    /// True when `other` names the same engine and either side leaves the variant open.
    public func matches(_ other: SpeechEngineVariantKey) -> Bool {
        guard engineID == other.engineID else { return false }
        guard let variant, let otherVariant = other.variant else { return true }
        return variant == otherVariant
    }
}

/// How an engine chooses the spoken language (upstream `SpeechEngineLanguagePolicy`).
public struct SpeechEngineLanguagePolicy: Equatable, Sendable {
    public enum Mode: Equatable, Sendable {
        /// Detected from the audio.
        case automatic
        /// One language only.
        case fixed
        /// A language the person picks (or the device's).
        case selectable
    }

    public let mode: Mode
    public let defaultLanguage: String?
    /// BCP-47 tags; nil = many or decided at run time.
    public let supportedLanguageCodes: [String]?

    public static func automatic(defaultLanguage: String? = nil, supportedLanguageCodes: [String]? = nil) -> Self {
        Self(mode: .automatic, defaultLanguage: defaultLanguage, supportedLanguageCodes: supportedLanguageCodes)
    }

    public static func fixed(_ language: String) -> Self {
        Self(mode: .fixed, defaultLanguage: language, supportedLanguageCodes: [language])
    }

    public static func selectable(defaultLanguage: String? = nil, supportedLanguageCodes: [String]? = nil) -> Self {
        Self(mode: .selectable, defaultLanguage: defaultLanguage, supportedLanguageCodes: supportedLanguageCodes)
    }

    /// Settings wording.
    public var summary: String {
        switch mode {
        case .automatic:
            if let count = supportedLanguageCodes?.count { return "Automatic (\(count) languages)" }
            return "Automatic"
        case .fixed:
            return Locale.current.localizedString(forLanguageCode: defaultLanguage ?? "") ?? defaultLanguage ?? "One"
        case .selectable:
            return "This iPhone’s language"
        }
    }
}

/// Model files: name, size, who manages them and how much memory the engine needs while loaded.
public struct SpeechEngineModelLifecycle: Equatable, Sendable {
    public let modelName: String
    /// Download size; nil when iOS manages the files (Apple's speech assets).
    public let approximateDownloadBytes: Int64?
    /// iOS downloads and stores the model (Apple Speech); the app only requests or releases it.
    public let isSystemManaged: Bool
    public let isUserDeletable: Bool
    /// Physical memory the device needs at least (upstream's floor); nil = no floor.
    public let minimumMemoryBytes: UInt64?
    /// About how much the app's memory grows while the model is loaded and running; nil when the model runs in a
    /// system process. Measured on the device before an engine is exposed (plan 016); until then an estimate.
    public let approximateRuntimeMemoryBytes: Int64?

    public init(
        modelName: String,
        approximateDownloadBytes: Int64?,
        isSystemManaged: Bool = false,
        isUserDeletable: Bool = true,
        minimumMemoryBytes: UInt64? = nil,
        approximateRuntimeMemoryBytes: Int64?
    ) {
        self.modelName = modelName
        self.approximateDownloadBytes = approximateDownloadBytes
        self.isSystemManaged = isSystemManaged
        self.isUserDeletable = isUserDeletable
        self.minimumMemoryBytes = minimumMemoryBytes
        self.approximateRuntimeMemoryBytes = approximateRuntimeMemoryBytes
    }
}

/// What one engine build can do, in one row (upstream ADR-026's capability registry).
public struct SpeechEngineCapabilities: Equatable, Sendable, Identifiable {
    public let key: SpeechEngineVariantKey
    /// Settings name, e.g. "Whisper Large v3 Turbo".
    public let displayName: String
    /// Short provider line, e.g. "WhisperKit · MIT".
    public let providerSummary: String
    /// Streams its own partials while someone speaks.
    public let supportsNativeLiveDictation: Bool
    /// Can preview by re-transcribing the last seconds (`TailWindowPreviewSession`).
    public let supportsTailPreview: Bool
    public let providesWordTimestamps: Bool
    public let supportedLanguages: SpeechEngineLanguagePolicy
    public let supportsCustomVocabulary: Bool
    public let modelLifecycle: SpeechEngineModelLifecycle
    /// Where inference runs, as Settings says it ("Neural Engine", "iOS speech service").
    public let runsOn: String

    public var id: SpeechEngineVariantKey { key }

    /// Can serve the live route (dictation preview, a meeting's live text).
    public var supportsLivePreview: Bool {
        supportsNativeLiveDictation || supportsTailPreview
    }

    /// A meeting's live text is segmented by word timings (upstream rule).
    public var supportsMeetingLivePreview: Bool {
        providesWordTimestamps
    }

    public init(
        key: SpeechEngineVariantKey,
        displayName: String,
        providerSummary: String,
        supportsNativeLiveDictation: Bool,
        supportsTailPreview: Bool,
        providesWordTimestamps: Bool,
        supportedLanguages: SpeechEngineLanguagePolicy,
        supportsCustomVocabulary: Bool,
        modelLifecycle: SpeechEngineModelLifecycle,
        runsOn: String
    ) {
        self.key = key
        self.displayName = displayName
        self.providerSummary = providerSummary
        self.supportsNativeLiveDictation = supportsNativeLiveDictation
        self.supportsTailPreview = supportsTailPreview
        self.providesWordTimestamps = providesWordTimestamps
        self.supportedLanguages = supportedLanguages
        self.supportsCustomVocabulary = supportsCustomVocabulary
        self.modelLifecycle = modelLifecycle
        self.runsOn = runsOn
    }
}

/// Whether an engine build fits this device and this build's memory budget.
public struct SpeechEngineMemoryRequirementStatus: Equatable, Sendable {
    public let key: SpeechEngineVariantKey
    public let modelName: String
    public let minimumMemoryBytes: UInt64?
    public let physicalMemoryBytes: UInt64
    public let approximateRuntimeMemoryBytes: Int64?
    public let budgetBytes: Int64

    public var isSatisfied: Bool {
        fitsPhysicalMemory && fitsBudget
    }

    public var fitsPhysicalMemory: Bool {
        guard let minimumMemoryBytes else { return true }
        return physicalMemoryBytes >= minimumMemoryBytes
    }

    public var fitsBudget: Bool {
        guard let approximateRuntimeMemoryBytes else { return true }
        return approximateRuntimeMemoryBytes <= budgetBytes
    }

    /// Why the engine cannot be chosen here, or nil.
    public var insufficientMemoryMessage: String? {
        if !fitsPhysicalMemory, let minimumMemoryBytes {
            return "\(modelName) needs \(Self.gigabytes(Int64(minimumMemoryBytes))) of memory or more — this "
                + "iPhone has less."
        }
        if !fitsBudget, let approximateRuntimeMemoryBytes {
            return "\(modelName) needs about \(Self.gigabytes(approximateRuntimeMemoryBytes)) while it runs, more "
                + "than this build’s \(Self.gigabytes(budgetBytes)) model budget."
        }
        return nil
    }

    static func gigabytes(_ bytes: Int64) -> String {
        String(format: "%.1f GB", Double(bytes) / 1_000_000_000)
    }
}

/// Optional for engines that cannot run on every device (Apple Speech is unavailable in the Simulator). Additive to
/// the plug-in contract: an engine without it is assumed to run anywhere its model is on disk.
public protocol SpeechEngineAvailabilityReporting: Sendable {
    /// Nil when the engine can run here; otherwise why not, in words the owner reads in Settings.
    func unavailableReason() async -> String?
}

/// Optional for engines that hold a model in the app's memory: drops it (the next `prepare` loads it again from
/// disk). The benchmark unloads between engines so each one's load time and peak memory are its own. Refused
/// silently while a job is using the model. Additive to the plug-in contract.
public protocol SpeechEngineUnloading: Sendable {
    func unloadModels() async
}

/// The table of every speech engine build iChirp knows, one row per variant (upstream `SpeechEngineCapabilityRegistry`).
/// Engines register instances in the app; this table is what Settings, the router and the benchmark read.
public enum SpeechEngineCapabilityRegistry {
    // Stable engine ids (never renamed; persisted in `Transcription.engine`).
    public static let parakeetEngineID = "fluidaudio.parakeet-tdt"
    public static let appleSpeechEngineID = "apple.speech-transcriber"
    public static let whisperKitEngineID = "argmax.whisperkit"

    /// About how much model memory a build without the Increased Memory Limit entitlement should use (spec/06: keep
    /// model weights around 2–3 GB; a 3.65 GB model failed to load on an iPhone 17 Pro without it).
    public static let memoryBudgetBytes: Int64 = 2_500_000_000

    /// Parakeet v3 on both routes (must not change: plan 016).
    public static let defaultKey = SpeechEngineVariantKey(engineID: parakeetEngineID)

    public static let all: [SpeechEngineCapabilities] =
        parakeetRows() + [appleSpeechRow()] + whisperRows()

    private static let table = Dictionary(uniqueKeysWithValues: all.map { ($0.key, $0) })

    /// The exact row, or — for a key with no variant — the engine's first row.
    public static func capabilitiesIfPresent(for key: SpeechEngineVariantKey) -> SpeechEngineCapabilities? {
        if let row = table[key] { return row }
        guard key.variant == nil else { return nil }
        return all.first { $0.key.engineID == key.engineID }
    }

    public static func memoryRequirementStatus(
        for capabilities: SpeechEngineCapabilities,
        physicalMemoryBytes: UInt64 = ProcessInfo.processInfo.physicalMemory,
        budgetBytes: Int64 = memoryBudgetBytes
    ) -> SpeechEngineMemoryRequirementStatus {
        SpeechEngineMemoryRequirementStatus(
            key: capabilities.key,
            modelName: capabilities.modelLifecycle.modelName,
            minimumMemoryBytes: capabilities.modelLifecycle.minimumMemoryBytes,
            physicalMemoryBytes: physicalMemoryBytes,
            approximateRuntimeMemoryBytes: capabilities.modelLifecycle.approximateRuntimeMemoryBytes,
            budgetBytes: budgetBytes
        )
    }

    // MARK: - Rows

    private static func parakeetRows() -> [SpeechEngineCapabilities] {
        [
            SpeechEngineCapabilities(
                key: SpeechEngineVariantKey(engineID: parakeetEngineID, variant: "v3"),
                displayName: "Parakeet v3",
                providerSummary: "FluidAudio · CC-BY-4.0",
                supportsNativeLiveDictation: false,
                supportsTailPreview: true,
                providesWordTimestamps: true,
                supportedLanguages: .automatic(supportedLanguageCodes: parakeetV3Languages),
                supportsCustomVocabulary: false,
                modelLifecycle: SpeechEngineModelLifecycle(
                    modelName: "Parakeet v3", approximateDownloadBytes: 500_000_000,
                    // Device smoke: 275–592 MB peak on the iPhone 17 Pro (docs/research/2026-09-22-device-benchmarks.md).
                    approximateRuntimeMemoryBytes: 800_000_000),
                runsOn: "Neural Engine"
            ),
            SpeechEngineCapabilities(
                key: SpeechEngineVariantKey(engineID: parakeetEngineID, variant: "v2"),
                displayName: "Parakeet v2",
                providerSummary: "FluidAudio · CC-BY-4.0",
                supportsNativeLiveDictation: false,
                supportsTailPreview: true,
                providesWordTimestamps: true,
                supportedLanguages: .fixed("en"),
                supportsCustomVocabulary: false,
                modelLifecycle: SpeechEngineModelLifecycle(
                    modelName: "Parakeet v2", approximateDownloadBytes: 500_000_000,
                    approximateRuntimeMemoryBytes: 800_000_000),
                runsOn: "Neural Engine"
            ),
        ]
    }

    private static func appleSpeechRow() -> SpeechEngineCapabilities {
        SpeechEngineCapabilities(
            key: SpeechEngineVariantKey(engineID: appleSpeechEngineID),
            displayName: "Apple Speech",
            providerSummary: "Apple SpeechTranscriber · built into iOS",
            supportsNativeLiveDictation: false,
            // Previewed through the tail window (the router), not SpeechAnalyzer's own streaming (not built yet).
            supportsTailPreview: true,
            providesWordTimestamps: true,
            supportedLanguages: .selectable(),
            supportsCustomVocabulary: false,
            modelLifecycle: SpeechEngineModelLifecycle(
                modelName: "Apple Speech", approximateDownloadBytes: nil, isSystemManaged: true,
                approximateRuntimeMemoryBytes: nil),
            runsOn: "iOS speech service"
        )
    }

    private static func whisperRows() -> [SpeechEngineCapabilities] {
        func row(
            _ variant: String, _ name: String, download: Int64, runtime: Int64
        ) -> SpeechEngineCapabilities {
            SpeechEngineCapabilities(
                key: SpeechEngineVariantKey(engineID: whisperKitEngineID, variant: variant),
                displayName: name,
                providerSummary: "WhisperKit · MIT",
                supportsNativeLiveDictation: false,
                supportsTailPreview: true,
                providesWordTimestamps: true,
                supportedLanguages: .automatic(),
                supportsCustomVocabulary: false,
                modelLifecycle: SpeechEngineModelLifecycle(
                    modelName: name, approximateDownloadBytes: download, approximateRuntimeMemoryBytes: runtime),
                runsOn: "Neural Engine + GPU"
            )
        }
        return [
            row("base", "Whisper Base", download: 151_000_000, runtime: 300_000_000),
            row("large-v3-turbo", "Whisper Large v3 Turbo", download: 650_000_000, runtime: 1_500_000_000),
            // Listed so the budget rule is visible; no engine instance is built for it.
            row("large-v3", "Whisper Large v3", download: 3_090_000_000, runtime: 3_600_000_000),
        ]
    }

    /// FluidAudio's Parakeet TDT v3 languages (25 European languages).
    public static let parakeetV3Languages = [
        "bg", "hr", "cs", "da", "nl", "en", "et", "fi", "fr", "de", "el", "hu", "it", "lv", "lt", "mt", "pl", "pt",
        "ro", "sk", "sl", "es", "sv", "ru", "uk",
    ]
}
