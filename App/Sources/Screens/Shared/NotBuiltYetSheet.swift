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
                // F94: a capsule, like every other primary button on the canvas — this one was the odd rounded
                // rectangle out.
                Text("Done")
                    .chirpFont(16, .semibold)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .background(Capsule().fill(Tokens.Color.accentFill))
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
