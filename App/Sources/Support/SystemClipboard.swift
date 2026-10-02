import ChirpFeatures
import UIKit
import UniformTypeIdentifiers

/// Where content text is written: `UIPasteboard` in the app, a recorder in tests.
@MainActor protocol PasteboardItemsWriting: AnyObject {
    func setItems(_ items: [[String: Any]], options: [UIPasteboard.OptionsKey: Any])
}

extension UIPasteboard: PasteboardItemsWriting {}

/// The one way content text (a dictation, a transcript, a typed note, a document) reaches the pasteboard: as plain
/// text with `.localOnly`, so it stays on this iPhone and never syncs over Universal Clipboard to the owner's other
/// Apple devices (spec/12-privacy.md; review R6a-1). Only non-content text (build details, a launch error) may use the
/// general pasteboard directly; `ClipboardPolicyTests` scans `App/Sources` for any other write.
@MainActor enum ContentClipboard {
    static func copy(_ text: String, to pasteboard: any PasteboardItemsWriting = UIPasteboard.general) {
        pasteboard.setItems([[UTType.plainText.identifier: text]], options: [.localOnly: true])
    }
}

/// Dictation's clipboard (M2): iOS lets an app write the pasteboard but not paste into another app, so dictation
/// copies and the person pastes. Local-only like every other Copy, which is what the Dictating screen promises
/// ("Audio and transcript never leave this iPhone").
@MainActor final class SystemClipboard: ClipboardWriting {
    private let pasteboard: any PasteboardItemsWriting

    init(pasteboard: any PasteboardItemsWriting = UIPasteboard.general) {
        self.pasteboard = pasteboard
    }

    func copy(_ text: String) {
        ContentClipboard.copy(text, to: pasteboard)
    }
}
