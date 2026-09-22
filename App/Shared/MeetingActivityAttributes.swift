import ActivityKit
import Foundation

/// The meeting Live Activity (M3), shared by the app (which starts, updates and ends it) and the widget extension
/// (which draws it). No App Group: the app pushes every state itself, like the dictation activity.
struct MeetingActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        enum Phase: String, Codable, Hashable {
            case recording, paused, interrupted, finishing, saved, failed
        }

        var phase: Phase
        /// Now minus the audio recorded so far, so `Text(timerInterval:)` counts recorded time while recording.
        var timerStart: Date
        /// Recorded seconds, shown frozen while not recording (paused, interrupted, finishing).
        var recordedSeconds: Int
        /// One short line ("Saving locally", "A call has the microphone", the failure).
        var detail: String?
    }

    /// "Meeting Sep 22, 9:41 AM".
    var title: String
}

/// The palette the extension draws the meeting activity with (same values as `ChirpUI.Tokens`).
enum MeetingActivityPalette {
    static let rosetteHex: UInt32 = 0x59A659
    static let recordRedHex: UInt32 = 0xE64D42
    static let stopRedHex: UInt32 = 0xC9342B
    static let coverNightHex: UInt32 = 0x16211D
}
