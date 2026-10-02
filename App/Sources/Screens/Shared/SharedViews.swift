import ChirpCore
import ChirpUI
import SwiftUI
import UIKit

/// A file handed to the system share sheet.
struct ShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

/// `UIActivityViewController` for exported files and text (Save to Files, AirDrop, Mail, …).
///
/// iOS's own Copy is left out (review R6b-2): it writes the general pasteboard, which syncs over Universal Clipboard,
/// and would bypass the local-only Copy every screen offers for transcripts and documents (`ContentClipboard`).
struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    /// Share-sheet activities Parakeet never offers.
    static let excludedActivityTypes: [UIActivity.ActivityType] = [.copyToPasteboard]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        Self.makeController(items: items)
    }

    static func makeController(items: [Any]) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        controller.excludedActivityTypes = excludedActivityTypes
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// Shown instead of the tabs when the library could not be opened. Nothing is deleted; the user can copy details.
struct LaunchErrorView: View {
    let message: String
    @State private var copied = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // The mark fills its frame now (R7-9): 24 pt beside a title, growing with the title's text style.
                ParakeetMarkView(accessibilityLabel: "Parakeet")
                    .chirpScaledFrame(width: 24, height: 24, relativeTo: .title2)
                Text("Parakeet couldn’t open your library")
                    .chirpTitleFont(24)
                    .foregroundStyle(Tokens.Color.ink)
                Text(
                    "Nothing was deleted: your transcripts and audio are still on this iPhone. Close Parakeet and "
                        + "open it again. If this keeps happening, copy the details below and send them to the developer."
                )
                .chirpFont(15)
                .foregroundStyle(Tokens.Color.secondary)
                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel("Details")
                    Text(details)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(Tokens.Color.ink)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .chirpCard(radius: Tokens.Radius.s, padding: 14)
                Button(copied ? "Copied" : "Copy details") {
                    // Not content: the error and the build, for the developer (the general pasteboard is fine here).
                    UIPasteboard.general.string = details
                    copied = true
                }
                .buttonStyle(.chirpPrimary)
            }
            .padding(24)
        }
        .background(Tokens.Color.ground)
    }

    private var details: String {
        "\(message)\nBuild: \(BuildIdentity.current.summary)"
    }
}

/// A short empty-state block: an optional symbol, a title, one line of guidance and an optional action that does what
/// the line says (R7-20: "Your library is empty" offers Create instead of telling the person where to find it).
struct EmptyStateView: View {
    /// The button under the guidance.
    struct Action {
        let title: String
        let perform: () -> Void
    }

    let title: String
    let message: String
    var systemImage: String?
    var action: Action?

    var body: some View {
        VStack(spacing: Tokens.Spacing.xs) {
            if let systemImage {
                Image(systemName: systemImage)
                    .chirpGlyph(28, .regular, relativeTo: .title2, maxScale: 1.6)
                    .foregroundStyle(Tokens.Color.mutedText)
                    .padding(.bottom, Tokens.Spacing.xxs)
                    .accessibilityHidden(true)
            }
            VStack(spacing: 6) {
                Text(title)
                    .chirpFont(15, .semibold)
                    .foregroundStyle(Tokens.Color.ink)
                Text(message)
                    .chirpFont(13)
                    .foregroundStyle(Tokens.Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .multilineTextAlignment(.center)
            .accessibilityElement(children: .combine)
            if let action {
                Button(action.title, action: action.perform)
                    .buttonStyle(.chirp(.filled, size: .compact))
                    .padding(.top, Tokens.Spacing.xxs)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Tokens.Spacing.xl)
        .padding(.horizontal, Tokens.Spacing.m)
    }
}
