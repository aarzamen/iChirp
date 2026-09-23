import Foundation

#if os(iOS)
import os
#endif

/// How much more memory iOS lets this app use right now before it terminates it (jetsam). Injected wherever a model
/// load is decided — the speech engines right before they load, the route rules and Settings → Speech engines — so
/// tests pass a fake and the app passes `ProcessAvailableMemory`. The number already excludes what the app holds now
/// (a model another route keeps loaded), and it rises with the Increased Memory Limit entitlement where the device
/// grants it.
public protocol AvailableMemoryReading: Sendable {
    /// Bytes the app may still allocate now, or nil where the system does not say (the Mac, the Simulator). Nil means
    /// "unknown": callers then skip the run-time fit check, never refuse.
    func availableMemoryBytes() -> UInt64?
}

/// `os_proc_available_memory()` on iOS; nil on the Mac and where the system reports 0 (the Simulator).
public struct ProcessAvailableMemory: AvailableMemoryReading {
    public init() {}

    public func availableMemoryBytes() -> UInt64? {
        #if os(iOS)
        let available = os_proc_available_memory()
        return available > 0 ? UInt64(available) : nil
        #else
        return nil
        #endif
    }
}

/// A fixed reading, for tests and previews.
public struct FixedAvailableMemory: AvailableMemoryReading {
    public let bytes: UInt64?

    public init(_ bytes: UInt64?) {
        self.bytes = bytes
    }

    public func availableMemoryBytes() -> UInt64? { bytes }
}
