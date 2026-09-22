import ChirpCore
import ChirpUI
import SwiftUI
import UIKit

/// A file handed to the system share sheet.
struct ShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

/// `UIActivityViewController` for exported files (Save to Files, AirDrop, Mail, …).
struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
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
                ParakeetMarkView(accessibilityLabel: "Parakeet")
                    .frame(width: 44, height: 44)
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
                Button {
                    UIPasteboard.general.string = details
                    copied = true
                } label: {
                    CapsuleButtonLabel(title: copied ? "Copied" : "Copy details", kind: .filled)
                }
                .buttonStyle(.plain)
            }
            .padding(24)
        }
        .background(Tokens.Color.ground)
    }

    private var details: String {
        "\(message)\nBuild: \(BuildIdentity.current.summary)"
    }
}

/// A short empty-state block: title and one line of guidance.
struct EmptyStateView: View {
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 6) {
            Text(title)
                .chirpFont(15, .semibold)
                .foregroundStyle(Tokens.Color.ink)
            Text(message)
                .chirpFont(13)
                .foregroundStyle(Tokens.Color.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .padding(.horizontal, 16)
        .accessibilityElement(children: .combine)
    }
}
