import Foundation

/// A model that does not fit what iOS lets the app use right now (fix/speech-memory-fit): which build, what a load
/// needs (`SpeechEngineModelLifecycle.memoryToLoadBytes`) and what the app can use now (`AvailableMemoryReading`).
/// Content-free: an engine build and two numbers.
public struct SpeechEngineMemoryShortfall: Equatable, Sendable {
    public let key: SpeechEngineVariantKey
    public let neededBytes: Int64
    public let availableBytes: UInt64

    public init(key: SpeechEngineVariantKey, neededBytes: Int64, availableBytes: UInt64) {
        self.key = key
        self.neededBytes = neededBytes
        self.availableBytes = availableBytes
    }

    /// The row's name ("Whisper Large v3 Turbo"), or the key for an engine without a row.
    public var engineName: String {
        SpeechEngineCapabilityRegistry.capabilitiesIfPresent(for: key)?.displayName ?? key.description
    }

    /// Settings → Speech engines: "Needs more memory than this iPhone gives Parakeet (about 2.1 GB)".
    public var settingsMessage: String {
        "Needs more memory than this iPhone gives Parakeet (about \(Self.gigabytes(Int64(clamping: availableBytes))))"
    }

    /// A refused load, as a job's error shows it (with Retry): "Whisper Large v3 Turbo needs about 3.5 GB of memory
    /// while it loads, and Parakeet can use about 2.1 GB right now. Close other apps or use Whisper Base."
    public var refusalMessage: String {
        let advice =
            SpeechEngineCapabilityRegistry.lighterAlternative(to: key, availableBytes: availableBytes)
            .map { "Close other apps or use \($0)." } ?? "Close other apps and try again."
        return "\(engineName) needs about \(Self.gigabytes(neededBytes)) of memory while it loads, and Parakeet can "
            + "use about \(Self.gigabytes(Int64(clamping: availableBytes))) right now. \(advice)"
    }

    static func gigabytes(_ bytes: Int64) -> String {
        SpeechEngineMemoryRequirementStatus.gigabytes(bytes)
    }
}

extension SpeechEngineCapabilityRegistry {
    /// What a load of `key` must find available (the row's `memoryToLoadBytes`); nil for an engine without a row or
    /// a row whose model runs in a system process (Apple Speech).
    public static func memoryToLoadBytes(for key: SpeechEngineVariantKey) -> Int64? {
        capabilitiesIfPresent(for: key)?.modelLifecycle.memoryToLoadBytes
    }

    /// Nil when `key` fits what `reader` says the app can use now, when the reader does not say (the Mac, the
    /// Simulator) or when the row has no estimate; otherwise the shortfall.
    public static func memoryShortfall(
        for key: SpeechEngineVariantKey, reader: any AvailableMemoryReading
    ) -> SpeechEngineMemoryShortfall? {
        memoryShortfall(for: key, availableBytes: reader.availableMemoryBytes())
    }

    /// The same check against one reading already taken (nil = unknown: never a shortfall), so a caller that checks
    /// several rules decides them all on the same number.
    public static func memoryShortfall(
        for key: SpeechEngineVariantKey, availableBytes: UInt64?
    ) -> SpeechEngineMemoryShortfall? {
        guard let needed = memoryToLoadBytes(for: key), let available = availableBytes,
            UInt64(max(needed, 0)) > available
        else { return nil }
        return SpeechEngineMemoryShortfall(key: key, neededBytes: needed, availableBytes: available)
    }

    /// The run-time fit check every speech engine makes right before it starts loading or compiling a model (never
    /// while joining a load already running): throws `SpeechEngineError.insufficientMemory` instead of letting iOS
    /// terminate the app, and the engine then loads nothing.
    public static func checkMemoryFit(for key: SpeechEngineVariantKey, reader: any AvailableMemoryReading) throws {
        if let shortfall = memoryShortfall(for: key, reader: reader) {
            throw SpeechEngineError.insufficientMemory(
                shortfall.key, needed: shortfall.neededBytes, available: shortfall.availableBytes)
        }
    }

    /// The most the distinct builds in `keys` need together at run time: one of them loading (its
    /// `memoryToLoadBytes`) while the others are already resident (their runtime estimates), for whichever loads last
    /// costs most. Rows without estimates count 0. The live-plus-final rule compares it with available memory.
    public static func combinedLoadMemoryBytes(for keys: [SpeechEngineVariantKey]) -> Int64 {
        var seen: Set<SpeechEngineVariantKey> = []
        var rows: [SpeechEngineModelLifecycle] = []
        for key in keys {
            guard let row = capabilitiesIfPresent(for: key), seen.insert(row.key).inserted else { continue }
            rows.append(row.modelLifecycle)
        }
        let resident = rows.reduce(Int64(0)) { $0 + ($1.approximateRuntimeMemoryBytes ?? 0) }
        return rows.map { resident - ($0.approximateRuntimeMemoryBytes ?? 0) + ($0.memoryToLoadBytes ?? 0) }.max() ?? 0
    }

    /// A lighter build to suggest when `key` does not fit: a smaller variant of the same engine first (Whisper Base
    /// for Turbo), then Parakeet v3, as long as it needs less and fits `availableBytes`. Nil when none does.
    static func lighterAlternative(to key: SpeechEngineVariantKey, availableBytes: UInt64) -> String? {
        guard let needed = memoryToLoadBytes(for: key) else { return nil }
        let sameEngine = all.filter { $0.key.engineID == key.engineID && $0.key != key }
        let parakeet: [SpeechEngineCapabilities] =
            key.engineID == parakeetEngineID ? [] : Array(all.filter { $0.key.engineID == parakeetEngineID }.prefix(1))
        for row in sameEngine + parakeet {
            guard let other = row.modelLifecycle.memoryToLoadBytes, other < needed,
                UInt64(max(other, 0)) <= availableBytes, other <= memoryBudgetBytes
            else { continue }
            return row.displayName
        }
        return nil
    }
}
