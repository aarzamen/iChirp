import Foundation

// Plan 020: the seam between `VoicePlayer` (ChirpFeatures) and the audio output (ChirpAudio's `SpeechPlaybackEngine`,
// through `AudioSessionController`). Semantics from Readback (the owner's macOS read-aloud app),
// `Sources/Audio/PlaybackEngine.swift`: an utterance is a sequence of chunks played back to back.

/// What the speech output reports while an utterance plays.
public enum SpeechPlaybackEvent: Sendable, Equatable {
    /// Chunk `index` started playing (the first one, the next one, or one that arrived after a gap).
    case chunkStarted(Int)
    /// Everything queued has played but the final chunk has not been queued yet (synthesis is behind).
    case drained
    /// The final chunk finished playing.
    case finished
    /// Something else took the audio (a call, Siri, a dictation or a meeting). Playback is paused and stays paused.
    case interrupted
    /// Playback failed and stopped; a sentence for the screen.
    case failed(String)
}

/// Plays one utterance's synthesized chunks in order, through the app's one audio session.
@MainActor
public protocol SpeechAudioPlaying: AnyObject {
    /// Receives the events of the current utterance.
    var onEvent: ((SpeechPlaybackEvent) -> Void)? { get set }
    /// Stops any previous utterance and takes the audio session for playback. Throws when it cannot be had (for
    /// example while Parakeet is recording); nothing plays then.
    func beginUtterance() throws
    /// Queues `audio` after what is already queued; the first chunk starts playback. `pauseAfterMs` inserts silence
    /// after it (paragraph ends); `isFinal` marks the utterance's last chunk.
    func enqueue(_ audio: SynthesizedAudio, index: Int, pauseAfterMs: Int, isFinal: Bool) throws
    func pause()
    /// Continues after `pause()` or an interruption. Throws when the audio session cannot be had.
    func resume() throws
    /// Stops at once, releases the audio session and deletes this utterance's temporary audio.
    func stop()
}
