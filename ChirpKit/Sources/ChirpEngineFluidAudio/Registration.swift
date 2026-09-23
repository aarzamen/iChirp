import ChirpCore

/// Builds the FluidAudio engines the app registers at launch.
public enum FluidAudioEngines {
    /// Parakeet in the user's chosen variant plus the offline diarizer, both in FluidAudio's default model cache
    /// and sharing the process-wide `ANEInferenceGate`. `availableMemory` is what iOS lets the app use now, checked
    /// before every Parakeet model load (fix/speech-memory-fit).
    public static func makeDefault(
        settings: TranscriptionSettings, availableMemory: any AvailableMemoryReading = ProcessAvailableMemory()
    ) -> (speech: ParakeetEngine, diarizer: FluidAudioDiarizer) {
        (
            speech: ParakeetEngine(variant: settings.parakeetVariant, gate: .shared, availableMemory: availableMemory),
            diarizer: FluidAudioDiarizer(gate: .shared)
        )
    }

    /// M3: Silero voice activity for meeting live chunks (CPU only), in FluidAudio's default model cache.
    public static func makeVoiceActivity() -> FluidAudioVoiceActivity {
        FluidAudioVoiceActivity()
    }
}
