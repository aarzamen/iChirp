import AppIntents
import Foundation

// M2 App Intents, compiled into both the app and the widget extension (a Control and a Live Activity button need the
// intent type in the extension). They always run in the app's process: the start and toggle intents open the app
// (`supportedModes = .foreground(.immediate)`, because iOS lets recording start only in the foreground), and the stop
// intent is a `LiveActivityIntent`, which iOS runs in the app. The extension build compiles the bodies out
// (`WIDGET_EXTENSION`), so it never touches the microphone or the dictation code.

/// "Dictate with Parakeet": opens Parakeet and starts recording. Returns once recording has begun (its Live Activity
/// exists by then, which an `AudioRecordingIntent` must provide) or the start failed.
struct StartDictationIntent: AudioRecordingIntent {
    static let title: LocalizedStringResource = "Dictate with Parakeet"
    static let description = IntentDescription(
        "Opens Parakeet and starts dictating. Stop to transcribe on this iPhone and copy the text.")
    static let supportedModes: IntentModes = .foreground(.immediate)

    @MainActor
    func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
        await DictationIntentRouter.start()
        #endif
        return .result()
    }
}

/// Start when nothing is recording, stop (transcribe and copy) when recording. For the Action Button and the Control.
struct ToggleDictationIntent: AudioRecordingIntent {
    static let title: LocalizedStringResource = "Start or Stop Dictation"
    static let description = IntentDescription(
        "Starts a Parakeet dictation, or stops the one that is recording and copies its text.")
    static let supportedModes: IntentModes = .foreground(.immediate)

    @MainActor
    func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
        await DictationIntentRouter.toggle()
        #endif
        return .result()
    }
}

/// The Live Activity's Stop: stops recording, runs the final pass and copies the text, then ends the activity.
/// Returns once the dictation has ended, so iOS keeps the app running for the final pass.
struct StopDictationIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Stop Dictation"
    static let description = IntentDescription("Stops the Parakeet dictation and copies its text.")
    static let isDiscoverable = false

    @MainActor
    func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
        await DictationIntentRouter.stop()
        #endif
        return .result()
    }
}
