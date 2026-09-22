// Ported from MacParakeet (GPL-3.0): Sources/MacParakeetCore/Services/MeetingRecording/MeetingVADService.swift @ bbae9e0e
// Changes: the protocol side only (`MeetingVADEvent`, `MeetingVADConfig`, `MeetingVoiceActivityDetecting`). The opaque
// FluidAudio stream state moves inside a stateful `VoiceActivityStream`, so ChirpCore never names FluidAudio; the
// conformer lives in ChirpEngineFluidAudio (engine plug-in rule).

import Foundation

/// A speech boundary found by voice-activity detection. Sample indexes count from the stream's first sample.
public enum VoiceActivityEvent: Sendable, Equatable {
    case speechStart
    /// Speech ended at `sampleIndex` (already padded by `VoiceActivityConfig.speechPaddingSeconds`).
    case speechEnd(sampleIndex: Int)
}

/// Upstream `MeetingVADConfig` defaults.
public struct VoiceActivityConfig: Sendable, Equatable {
    /// Silence needed before a speech end is reported.
    public var minSilenceSeconds: Double
    /// Audio kept on each side of speech.
    public var speechPaddingSeconds: Double

    public init(minSilenceSeconds: Double = 0.50, speechPaddingSeconds: Double = 0.15) {
        self.minSilenceSeconds = minSilenceSeconds
        self.speechPaddingSeconds = speechPaddingSeconds
    }
}

/// One running detection over one recording, in order. Stateful; used by one caller at a time.
public protocol VoiceActivityStream: Sendable {
    /// Feeds exactly `VoiceActivityDetecting.windowSize` 16 kHz mono samples (fewer only for the final flush).
    func process(_ window: [Float]) async throws -> VoiceActivityEvent?
}

/// A voice-activity detector plug-in (M3: Silero VAD on the CPU, so the Neural Engine stays free for Parakeet).
public protocol VoiceActivityDetecting: ModelAssetManaging {
    var descriptor: EngineDescriptor { get }
    /// Samples per `VoiceActivityStream.process` call (Silero: 4096, 256 ms at 16 kHz).
    var windowSize: Int { get }
    /// A fresh stream, or nil when the model is not on disk. Never downloads.
    func makeStream(config: VoiceActivityConfig) async -> (any VoiceActivityStream)?
}
