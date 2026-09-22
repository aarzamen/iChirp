import Foundation

/// Whether the person has let the app use the microphone.
public enum MicrophonePermission: Sendable, Equatable {
    case undetermined, denied, granted
}

/// What happened to the microphone while a recording runs. Every case keeps what was already recorded.
public enum CaptureEvent: Sendable, Equatable {
    /// A phone call, Siri or an alarm took the microphone. No audio arrives until `resumed`.
    case interrupted
    /// Audio flows again (after an interruption, a route change or a media-services reset).
    case resumed
    /// The interruption ended but iOS did not ask the app to resume: the person chooses Resume or Stop.
    case waitingForResume
    /// A headset connected or left; recording continues on the new input.
    case routeChanged
    /// The microphone stopped and could not restart. The recording so far is intact; stop it to keep it.
    case failed(message: String)
}

/// One item of a running recording's update stream.
public enum CaptureUpdate: Sendable, Equatable {
    /// Newly recorded audio, 16 kHz mono Float32, exactly as written to the file (for a live preview).
    case samples([Float])
    /// Smoothed input level in 0…1 for a waveform.
    case level(Float)
    case event(CaptureEvent)
}

/// A finished recording: a 16 kHz mono Float32 WAV.
public struct RecordedAudio: Sendable, Equatable {
    public var url: URL
    public var durationMs: Int
    public var sampleCount: Int

    public init(url: URL, durationMs: Int, sampleCount: Int) {
        self.url = url
        self.durationMs = durationMs
        self.sampleCount = sampleCount
    }
}

public enum AudioCaptureError: Error, Equatable, LocalizedError {
    case microphonePermissionDenied
    /// Shorter than the speech engines' minimum (0.3 s). The tiny file is removed.
    case tooShort
    case alreadyRecording
    case notRecording
    /// The microphone or the output file could not start.
    case startFailed(String)

    public var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied:
            "Parakeet needs the microphone to dictate. Turn it on in Settings → Privacy & Security → Microphone."
        case .tooShort:
            "That was too short to transcribe. Keep talking a moment longer before you stop."
        case .alreadyRecording:
            "A recording is already running."
        case .notRecording:
            "Nothing is recording."
        case .startFailed(let reason):
            "The microphone could not start: \(reason)"
        }
    }
}

/// Records the microphone into a 16 kHz mono WAV (M2 dictation). The implementation lives in ChirpAudio; view models
/// see only this protocol, so they are tested with a fake.
///
/// One recording at a time. `start` returns the recording's updates; the stream finishes after `stop` or `cancel`.
public protocol AudioCapturing: Sendable {
    func microphonePermission() -> MicrophonePermission
    /// Shows the system prompt when undetermined; returns whether access is granted.
    func requestMicrophonePermission() async -> Bool
    /// Starts recording to `url` (its folder must exist). Throws `AudioCaptureError`.
    func start(recordingTo url: URL) async throws -> AsyncStream<CaptureUpdate>
    /// After `CaptureEvent.waitingForResume` (or `failed`): try to restart the microphone into the same file.
    func resume() async throws
    /// Stops and finishes the file. Throws `AudioCaptureError.tooShort` (and removes the file) under 0.3 s.
    func stop() async throws -> RecordedAudio
    /// Stops and deletes the file: the person discarded this recording.
    func cancel() async
}

/// 16 kHz: the rate every speech engine takes and every recording is written at.
public enum SpeechAudio {
    public static let sampleRate = 16_000
    /// Speech engines reject shorter input (FluidAudio's 0.3 s guard, upstream `AudioRecorder`).
    public static let minimumSamples = 4_800
}
