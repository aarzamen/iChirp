// Ported from MacParakeet (GPL-3.0): Sources/MacParakeetCore/STT/ParakeetTDTASRConfig.swift @ bbae9e0e
// macOS keeps upstream's policy; iOS caps long-file chunk concurrency at `ChirpTuning.parakeetParallelChunks`.

import CoreML
import FluidAudio

/// Tunables that trade speed against memory and heat on the phone. Each value is benchmarked on device
/// (plan Task 13) before it changes.
public enum ChirpTuning {
    /// Long files are split into 15 s windows. FluidAudio's default decodes four windows at once on the same
    /// compiled models. On iPhone that multiplies peak memory and heat for little wall-clock gain, so iChirp
    /// starts at two.
    public static let parakeetParallelChunks = 2
}

/// FluidAudio `ASRConfig` and load-time encoder compute units for iChirp's Parakeet TDT `AsrManager`.
///
/// On macOS this mirrors upstream exactly: macOS 14's Neural Engine prediction path is not reentrant
/// (MacParakeet issue #997), and ``ANEInferenceGate`` only wraps the outer `transcribe` call, so when
/// serialization is required this type also sets `parallelChunkConcurrency: 1` and moves the conformer encoder
/// to `.cpuAndGPU`. macOS 15+ keeps FluidAudio's defaults.
///
/// On iOS serialization is never required (see ``ANEInferenceGate``), the encoder stays on FluidAudio's ANE
/// default, and chunk concurrency comes from ``ChirpTuning/parakeetParallelChunks``.
enum ParakeetASRConfig {
    static func make(
        serializationRequired: Bool = ANEInferenceGate.serializationRequiredForCurrentOS
    ) -> ASRConfig {
        #if os(macOS)
        guard serializationRequired else { return .default }
        return ASRConfig(parallelChunkConcurrency: 1)
        #else
        return ASRConfig(parallelChunkConcurrency: serializationRequired ? 1 : ChirpTuning.parakeetParallelChunks)
        #endif
    }

    /// `nil` leaves FluidAudio's ANE encoder default. `.cpuAndGPU` only when serialization is required.
    static func encoderComputeUnits(
        serializationRequired: Bool = ANEInferenceGate.serializationRequiredForCurrentOS
    ) -> MLComputeUnits? {
        guard serializationRequired else { return nil }
        return .cpuAndGPU
    }
}
