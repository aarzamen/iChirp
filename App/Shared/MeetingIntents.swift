import AppIntents
import Foundation

// M3 App Intents for the meeting Live Activity's buttons, compiled into the app and the widget extension. They are
// `LiveActivityIntent`s, so iOS runs them in the app's process; the extension build compiles the bodies out
// (`WIDGET_EXTENSION`). A meeting starts only from the app (iOS lets recording start only in the foreground).

/// Stop & save: stops recording and runs the final pass. Returns once the transcript is saved (or the pass failed),
/// so iOS keeps the app running for it.
struct StopMeetingIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Stop and Save Meeting"
    static let description = IntentDescription(
        "Stops the Parakeet meeting recording and transcribes it on this iPhone.")
    static let isDiscoverable = false

    @MainActor
    func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
        await MeetingIntentRouter.stop()
        #endif
        return .result()
    }
}

/// Pause or resume the meeting recording (the microphone stays on while paused).
struct ToggleMeetingPauseIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Pause or Resume Meeting"
    static let description = IntentDescription("Pauses the Parakeet meeting recording, or resumes it.")
    static let isDiscoverable = false

    @MainActor
    func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
        MeetingIntentRouter.togglePause()
        #endif
        return .result()
    }
}
