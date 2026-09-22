import Foundation

/// A live transcription session for display while someone speaks (M2 dictation; M3 meetings and M7 streaming
/// engines plug in here too).
///
/// **Display-only.** Nothing a live session produces is ever copied, pasted or saved: the kept text always comes
/// from a final pass over the recorded file (`SpeechEngine.transcribe(fileAt:options:progress:)`). A tail-window
/// engine's texts each cover only its recent window; a streaming engine's texts are cumulative partials. Either way
/// the caller stabilizes them for display (`ChirpText.LiveTranscriptStabilizer`).
///
/// Lifecycle: the provider returns a running session → `append` samples in order → `finish()` (or `cancel()`), which
/// stops taking audio, cancels and awaits any work in flight, and ends `updates`. After that the engine is free for
/// the final pass.
public protocol LiveSpeechSession: Sendable {
    /// The engine's current hypothesis text, each time it changes. Ends after `finish()` or `cancel()`.
    var updates: AsyncStream<String> { get }
    /// 16 kHz mono Float32 samples, in recording order.
    func append(_ samples: [Float]) async
    /// Stops the session and waits until no work of it is running.
    func finish() async
    /// Same as `finish()`; says the caller is discarding the recording.
    func cancel() async
}

/// A speech engine that can show live text. Engines without it simply have no preview.
public protocol LiveSpeechSessionProviding: Sendable {
    /// A running session, or nil when the engine cannot preview right now (for example, no model on disk). The
    /// session's inference runs through `scheduler` on the interactive (`.dictation`) path, so it never waits for a
    /// background file job, and at most one of its passes runs at a time.
    func makeLiveSession(
        scheduler: SpeechJobScheduler, options: SpeechTranscriptionOptions
    ) async -> (any LiveSpeechSession)?
}
