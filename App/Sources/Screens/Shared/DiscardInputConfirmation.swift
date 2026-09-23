import SwiftUI

/// Typed text is never lost to a dismissal (UX audit F19, F24; AGENTS §4 "never lose user data"): while the sheet holds
/// input, swipe-down and tap-outside do nothing, and Cancel asks "Discard …?" (Discard / Keep editing) before it goes.
/// Put it on the sheet's root view; the Cancel button sets `isAsking` when `hasInput` (`DiscardDecision`).
struct DiscardInputConfirmation: ViewModifier {
    let title: String
    let message: String
    let hasInput: Bool
    @Binding var isAsking: Bool
    var discardLabel = "Discard"
    var keepLabel = "Keep Editing"
    let discard: () -> Void

    func body(content: Content) -> some View {
        content
            .interactiveDismissDisabled(hasInput)
            .confirmationDialog(title, isPresented: $isAsking, titleVisibility: .visible) {
                Button(discardLabel, role: .destructive, action: discard)
                Button(keepLabel, role: .cancel) {}
            } message: {
                Text(message)
            }
    }
}

/// What a sheet's Cancel does: close at once, or ask first because something typed would be lost.
enum DiscardDecision: Equatable {
    case close
    case ask

    static func onCancel(hasInput: Bool) -> DiscardDecision {
        hasInput ? .ask : .close
    }

    /// Whether `text` holds anything worth asking about (whitespace alone is not input).
    static func holdsInput(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

extension View {
    /// Swipe-down is off while `hasInput`; `isAsking` shows the discard question, whose Discard runs `discard`.
    func discardInputConfirmation(
        _ title: String, message: String, hasInput: Bool, isAsking: Binding<Bool>, discardLabel: String = "Discard",
        keepLabel: String = "Keep Editing", discard: @escaping () -> Void
    ) -> some View {
        modifier(
            DiscardInputConfirmation(
                title: title, message: message, hasInput: hasInput, isAsking: isAsking, discardLabel: discardLabel,
                keepLabel: keepLabel, discard: discard))
    }
}
