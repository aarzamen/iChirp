import SwiftUI
import WidgetKit

/// The widget extension (M2): the dictation Live Activity and the Dictate Control. No widgets for the Home Screen yet.
@main
struct ParakeetWidgets: WidgetBundle {
    var body: some Widget {
        DictationLiveActivityWidget()
        DictationControl()
    }
}
