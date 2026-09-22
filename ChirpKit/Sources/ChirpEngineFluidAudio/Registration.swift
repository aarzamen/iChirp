import ChirpCore

/// Builds the FluidAudio engines the app registers at launch.
public enum FluidAudioEngines {
    /// Parakeet in the user's chosen variant plus the offline diarizer, both in FluidAudio's default model cache
    /// and sharing the process-wide `ANEInferenceGate`.
    public static func makeDefault(
        settings: TranscriptionSettings
    ) -> (speech: ParakeetEngine, diarizer: FluidAudioDiarizer) {
        (
            speech: ParakeetEngine(variant: settings.parakeetVariant, gate: .shared),
            diarizer: FluidAudioDiarizer(gate: .shared)
        )
    }
}
