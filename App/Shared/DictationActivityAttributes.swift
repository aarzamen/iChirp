import ActivityKit
import Foundation

/// The dictation Live Activity (M2), shared by the app (which starts, updates and ends it) and the widget extension
/// (which draws it on the Lock Screen and in the Dynamic Island). No App Group: the app pushes every state itself.
struct DictationActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        enum Phase: String, Codable, Hashable {
            case recording, paused, finishing, copied, failed
        }

        var phase: Phase
        /// Now minus the audio recorded so far, so `Text(timerInterval:)` shows recorded time without per-second
        /// updates. Re-sent on every state change (a pause does not advance it in the app).
        var timerStart: Date
        /// One short line for the finished states ("Copied", the failure reason).
        var detail: String?
    }

    /// "Parakeet v3", shown as the model in use.
    var modelName: String
}

/// The palette the extension draws with (it does not link ChirpUI). Same values as `ChirpUI.Tokens`.
enum DictationActivityPalette {
    static let accentHex: UInt32 = 0xE86B3B
    static let dictationAccentHex: UInt32 = 0xFF8A5C
    static let recordRedHex: UInt32 = 0xE64D42
    static let successHex: UInt32 = 0x33A854
    static let nightHex: UInt32 = 0x141417
}
