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

    // Scaled metrics instead of fixed point sizes (F3): each follows Dynamic Type from a canvas-matching default,
    // the same idea as the App layer's `chirpTitleFont`/`chirpFont` (ChirpUI can't see those App-only helpers, so
    // this view keeps its own private scaled metrics).
    @ScaledMetric(relativeTo: .title3) private var titleSize: CGFloat = 20
    @ScaledMetric(relativeTo: .caption2) private var badgeSize: CGFloat = 11.5
    @ScaledMetric(relativeTo: .subheadline) private var summarySize: CGFloat = 14

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
            .accessibilityHidden(true)  // Decorative; the combined label below says it all.

            VStack(spacing: 8) {
                Text(title)
                    .font(Tokens.Font.rounded(titleSize, .bold))
                    .foregroundStyle(Tokens.Color.ink)
                    .multilineTextAlignment(.center)

                Text(milestone.uppercased())
                    .font(.system(size: badgeSize, weight: .bold))
                    .tracking(0.6)
                    // Text on `tint`: `accentInkPressed` (about 7:1), not `accentInk` (4.39:1 in light mode, F8).
                    .foregroundStyle(Tokens.Color.accentInkPressed)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Tokens.Color.tint)
                    .clipShape(Capsule())
            }

            Text(summary)
                .font(.system(size: summarySize))
                .foregroundStyle(Tokens.Color.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 36)
        .frame(maxWidth: .infinity)
        .background(Tokens.Color.ground)
        // One VoiceOver stop for the whole placeholder: title, milestone, then the summary.
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(milestone), \(summary)")
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
