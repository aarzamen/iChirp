import Foundation

/// What the Dictating screen's Cancel asks before it discards (UX audit F72).
///
/// Cancel is the explicit discard: while recording it deletes the recording, and during the final pass it deletes the
/// row and its audio (`DictationCoordinator.cancel()`). A false start (under `confirmAfterSeconds` of recorded audio)
/// is still discarded with one tap; anything longer asks first ("Discard this 3-minute dictation?"). This type only
/// decides the question and its words; the discard itself stays `DictationCoordinator.cancel()`.
public struct DictationDiscardPrompt: Equatable, Sendable {
    /// Recorded audio at or above this asks before Cancel discards it. Shorter is a false start: discarded at once.
    public static let confirmAfterSeconds: TimeInterval = 5

    /// "Discard this 3-minute dictation?"
    public let title: String
    /// What goes and what stays.
    public let message: String
    /// The destructive button.
    public let discardTitle: String
    /// The button that keeps the dictation going.
    public let keepTitle: String

    /// The question Cancel asks now, or nil when Cancel discards at once: a false start, nothing recorded yet, or a
    /// state where there is nothing left to discard (`canDiscard(in:)` is false).
    public static func forCancel(state: DictationFlowState, recordedSeconds: TimeInterval) -> DictationDiscardPrompt? {
        guard canDiscard(in: state), recordedSeconds >= confirmAfterSeconds else { return nil }
        let length = lengthPhrase(seconds: recordedSeconds)
        if state == .stopping {
            return DictationDiscardPrompt(
                title: "Discard this \(length) dictation?",
                message: "The transcription stops, and the recording and its text are deleted from this iPhone. "
                    + "Nothing is copied.",
                discardTitle: "Discard dictation",
                keepTitle: "Keep transcribing")
        }
        return DictationDiscardPrompt(
            title: "Discard this \(length) dictation?",
            message: "The recording and its text are deleted from this iPhone. Nothing is copied.",
            discardTitle: "Discard dictation",
            keepTitle: "Keep dictating")
    }

    /// Whether Cancel still discards something in `state` (the flow ignores it once the dictation has ended).
    public static func canDiscard(in state: DictationFlowState) -> Bool {
        switch state {
        case .starting, .recording, .paused, .pendingStop, .stopping: true
        case .idle, .done, .failed, .cancelled: false
        }
    }

    /// "12-second", "1-minute", "3-minute" (nearest whole minute from one minute on).
    static func lengthPhrase(seconds: TimeInterval) -> String {
        let whole = max(Int(seconds), 0)
        if whole < 60 { return "\(whole)-second" }
        let minutes = max(Int((Double(whole) / 60).rounded()), 1)
        return "\(minutes)-minute"
    }
}
