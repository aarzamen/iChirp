// Ported from MacParakeet (GPL-3.0): Sources/MacParakeetCore/Services/ANEInferenceGate.swift @ bbae9e0e
// iOS policy: the macOS 14 check stays under #if os(macOS), iOS never serializes; the body runs in the caller's
// isolation (Swift 6 strict concurrency) instead of being sent to the generic executor.

import Foundation

/// Serializes CoreML / Neural Engine inference process-wide where the OS requires it.
///
/// On macOS 14 (Sonoma) the Neural Engine's shared execution queue
/// intermittently bus-errors (SIGBUS — a write into read-only mmapped model
/// weights) when two CoreML inferences run concurrently. FluidAudio tracks this
/// upstream as issue #661. MacParakeet hit it from two directions: concurrent
/// transcription lanes sharing one loaded model bundle, and offline diarization
/// running its own Neural Engine models outside the speech scheduler.
///
/// macOS 15+ rewrote the Neural Engine runtime and does not exhibit it, and
/// iOS 26 ships the same CoreML generation as macOS 26, so on iOS the gate is
/// always a **no-op**: callers keep full concurrency and pay nothing. The type
/// stays so engines gate every inference in one place, and so a future OS
/// regression can be handled by flipping one policy.
public final class ANEInferenceGate: Sendable {

    /// Shared process-wide gate. The Neural Engine is a single hardware
    /// resource, so one gate per process is the correct scope.
    public static let shared = ANEInferenceGate()

    /// `true` on the OS versions where concurrent Neural Engine inference is
    /// known to SIGBUS (macOS 14 and older); `false` on macOS 15+ and on iOS.
    public static var serializationRequiredForCurrentOS: Bool {
        #if os(macOS)
        if #available(macOS 15.0, *) { false } else { true }
        #else
        return false
        #endif
    }

    private let serializationRequired: Bool
    private let permit = AsyncPermit(value: 1)

    /// - Parameter serializationRequired: whether to serialize. Defaults to the
    ///   current OS policy; overridable so the behavior can be unit-tested on any
    ///   host.
    public init(serializationRequired: Bool = ANEInferenceGate.serializationRequiredForCurrentOS) {
        self.serializationRequired = serializationRequired
    }

    /// Runs `body` with exclusive Neural Engine access when serialization is
    /// required; runs it directly (no serialization, no suspension) otherwise.
    ///
    /// `body` runs in the caller's isolation, so an actor can gate a call on
    /// state it owns without sending that state anywhere.
    ///
    /// Callers must not nest calls to this method: the gate is a plain mutex,
    /// not reentrant, so a nested acquisition would deadlock when serializing.
    /// Gate at one level per inference (the FluidAudio calls that run CoreML,
    /// plus the diarization process call), never around an already-gated call.
    public func withExclusiveAccess<T>(
        isolation: isolated (any Actor)? = #isolation,
        _ body: () async throws -> T
    ) async throws -> T {
        guard serializationRequired else {
            return try await body()
        }
        try await permit.wait()
        defer { permit.signal() }
        return try await body()
    }
}
