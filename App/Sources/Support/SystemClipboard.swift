import ChirpFeatures
import UIKit

/// The general pasteboard. iOS lets an app write it but not paste into another app, so dictation copies and the
/// person pastes (M2).
@MainActor final class SystemClipboard: ClipboardWriting {
    func copy(_ text: String) {
        UIPasteboard.general.string = text
    }
}
