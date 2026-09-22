import Foundation

/// Records a meeting's microphone into a crash-readable file (M3). The implementation lives in ChirpAudio
/// (`MeetingRecorder`); the meeting coordinator sees only this protocol, so it is tested with a fake.
///
/// Differences from `AudioCapturing` (dictation):
/// - The file is `meeting.caf` (16 kHz mono 16-bit PCM, `spec/contracts/meeting-session-v1.md`): everything written
///   stays readable if the process is killed, with no repair.
/// - **Nothing here deletes audio.** `stop` keeps even a very short file and `cancel` only stops; the coordinator
///   decides what to delete, and only after the person confirmed.
/// - Pause and mute keep the microphone running, so iOS keeps the app alive in the background (a recording cannot be
///   started again from the background).
public protocol MeetingAudioCapturing: Sendable {
    func microphonePermission() -> MicrophonePermission
    /// Shows the system prompt when undetermined; returns whether access is granted.
    func requestMicrophonePermission() async -> Bool
    /// Creates the file at `url` (its folder must exist) and starts recording into it. Throws `AudioCaptureError`.
    /// The stream's `.samples` are exactly what was written (never while paused; zeros while muted).
    func start(recordingTo url: URL) async throws -> AsyncStream<CaptureUpdate>
    /// Paused: nothing is written or yielded, and the recorded time stops. The microphone stays on.
    func setPaused(_ paused: Bool) async
    /// Muted: silence is written in place of the microphone, so the recording's clock keeps running.
    func setMuted(_ muted: Bool) async
    /// After `CaptureEvent.waitingForResume` (or `failed`): try to restart the microphone into the same file.
    func resume() async throws
    /// Stops and closes the file. Never deletes it. Throws `AudioCaptureError.notRecording` when idle.
    func stop() async throws -> RecordedAudio
    /// Stops and closes the file without deleting it (the person is discarding; the coordinator deletes the folder).
    func cancel() async
}
