import ChirpUI
import SwiftUI

/// One unbuilt feature: what it will do and the milestone that ships it. Shown by `NotBuiltYetSheet`; never a
/// spinner, never a fake result.
struct Placeholder: Identifiable, Equatable {
    let id: String
    let title: String
    /// "M2", "M3", …
    let milestone: String
    let summary: String
    let systemImage: String

    /// The badge line: "Not built yet — milestone M2".
    var badge: String { "Not built yet — milestone \(milestone)" }
}

extension Placeholder {
    static let dictation = Placeholder(
        id: "dictation", title: "Dictate", milestone: "M2",
        summary: "Press the Action Button, or tap to go hands-free. Clean text lands on your clipboard.",
        systemImage: "waveform")
    static let pasteLink = Placeholder(
        id: "paste-link", title: "Paste a link", milestone: "M5",
        summary: "Paste a YouTube, podcast or X link and Parakeet transcribes it on this iPhone.",
        systemImage: "link")
    static let recordMeeting = Placeholder(
        id: "record-meeting", title: "Record Meeting", milestone: "M3",
        summary: "Record from the microphone with a live transcript, then save it with speaker labels, on device.",
        systemImage: "record.circle")
    static let notes = Placeholder(
        id: "notes", title: "Notes", milestone: "M3",
        summary: "Notes you write while a meeting records, kept next to its transcript.",
        systemImage: "note.text")
    static let ask = Placeholder(
        id: "ask", title: "Ask", milestone: "M4",
        summary: "Ask questions about this transcript and get answers that cite the moments they come from.",
        systemImage: "bubble.left.and.text.bubble.right")
    static let transform = Placeholder(
        id: "transform", title: "Transform", milestone: "M4",
        summary: "Rewrite a transcript with Polish, Distill, Decide or your own Transforms.",
        systemImage: "sparkles")
    static let dictationTrigger = Placeholder(
        id: "dictation-trigger", title: "Dictation trigger", milestone: "M2",
        summary: "Choose how dictation starts: the Action Button, a Shortcut, or the Dictate card.",
        systemImage: "button.programmable")
    static let backTap = Placeholder(
        id: "back-tap", title: "Back Tap", milestone: "M2",
        summary: "Back Tap is an iPhone Accessibility setting that runs a Shortcut. M2 adds the Parakeet shortcut "
            + "and shows how to assign it.",
        systemImage: "hand.tap")
    static let stopMode = Placeholder(
        id: "stop-mode", title: "Stop mode", milestone: "M2",
        summary: "Choose whether dictation stops when you tap or when you stop speaking.",
        systemImage: "stop.circle")
    static let cloudModels = Placeholder(
        id: "cloud-models", title: "Cloud models", milestone: "M4",
        summary: "Optionally let Ask and Transforms use a cloud model you set up. Off by default; clinical items "
            + "stay on device.",
        systemImage: "cloud")
    static let customWords = Placeholder(
        id: "custom-words", title: "Custom words & snippets", milestone: "M2",
        summary: "Teach Parakeet names and terms, and expand short phrases into longer text.",
        systemImage: "character.book.closed")
    static let gridLayout = Placeholder(
        id: "grid-layout", title: "Grid layout", milestone: "M8",
        summary: "Browse the Library as a grid of covers.",
        systemImage: "square.grid.2x2")
}

/// The shared "Not built yet" sheet: `NotBuiltYetView` plus a Done button.
struct NotBuiltYetSheet: View {
    let placeholder: Placeholder
    @Environment(\.dismiss) private var dismiss

    init(placeholder: Placeholder) {
        self.placeholder = placeholder
    }

    /// The plan's `NotBuiltYetSheet(title:milestone:summary:)` shape.
    init(title: String, milestone: String, summary: String) {
        self.placeholder = Placeholder(
            id: title, title: title, milestone: milestone, summary: summary, systemImage: "hammer")
    }

    var body: some View {
        VStack(spacing: 0) {
            NotBuiltYetView(
                title: placeholder.title,
                milestone: placeholder.badge,
                summary: placeholder.summary,
                systemImage: placeholder.systemImage
            )
            Button {
                dismiss()
            } label: {
                Text("Done")
                    .chirpFont(16, .semibold)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .background(
                        RoundedRectangle(cornerRadius: Tokens.Radius.s, style: .continuous)
                            .fill(Tokens.Color.accentInk))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Tokens.Color.ground)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}
