import AppIntents
import SwiftUI
import WidgetKit

/// A Control (Control Center, Lock Screen, or the Action Button → Controls) that starts a dictation, or stops the one
/// recording and copies its text. It opens Parakeet, because iOS allows recording to start only in the foreground.
struct DictationControl: ControlWidget {
    static let kind = "com.aarzamen.ichirp.control.dictate"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: ToggleDictationIntent()) {
                Label("Dictate", systemImage: "waveform")
            }
        }
        .displayName("Dictate with Parakeet")
        .description("Start or stop a dictation. The text is copied when you stop.")
    }
}
