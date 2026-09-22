import SwiftUI
import WidgetKit

/// The widget extension (M2): the dictation Live Activity and the Dictate Control; M3 adds the meeting Live Activity.
/// No widgets for the Home Screen yet.
@main
struct ParakeetWidgets: WidgetBundle {
    var body: some Widget {
        DictationLiveActivityWidget()
        DictationControl()
        MeetingLiveActivityWidget()
    }
}
