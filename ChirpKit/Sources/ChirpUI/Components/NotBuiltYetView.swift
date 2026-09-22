import SwiftUI

/// An honest placeholder for a feature that doesn't exist yet: a title, the milestone that
/// will ship it, a one-sentence summary of what it will do, and an SF Symbol. Never a spinner,
/// never a fake result — see `docs/plans/2026-09-22-001-feat-iphone-app-design-handoff.md`'s
/// "Placeholder sheet copy" section.
///
/// This is the content view only; the app's `NotBuiltYetSheet` (Task 12b) wraps it in a sheet
/// with a Done button.
public struct NotBuiltYetView: View {
    public var title: String
    public var milestone: String
    public var summary: String
    public var systemImage: String

    public init(title: String, milestone: String, summary: String, systemImage: String = "hammer") {
        self.title = title
        self.milestone = milestone
        self.summary = summary
        self.systemImage = systemImage
    }

    public var body: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(Tokens.Color.tint)
                    .frame(width: 64, height: 64)
                Image(systemName: systemImage)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(Tokens.Color.accentInk)
            }

            VStack(spacing: 8) {
                Text(title)
                    .font(Tokens.Font.rounded(20, .bold))
                    .foregroundStyle(Tokens.Color.ink)
                    .multilineTextAlignment(.center)

                Text(milestone.uppercased())
                    .font(.system(size: 11.5, weight: .bold))
                    .tracking(0.6)
                    .foregroundStyle(Tokens.Color.accentInk)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Tokens.Color.tint)
                    .clipShape(Capsule())
            }

            Text(summary)
                .font(.system(size: 14))
                .foregroundStyle(Tokens.Color.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 36)
        .frame(maxWidth: .infinity)
        .background(Tokens.Color.ground)
    }
}

#Preview("NotBuiltYetView") {
    NotBuiltYetView(
        title: "Dictation",
        milestone: "Milestone M2",
        summary: "Press the Action Button or tap to dictate; clean text lands on your clipboard.",
        systemImage: "waveform"
    )
}
