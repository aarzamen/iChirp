import ChirpFeatures
import ChirpUI
import SwiftUI

/// A section's uppercase label with an optional link at the trailing edge ("RECIPES · Edit", "RECENT · See all"),
/// and the one gap between it and the section's content (R7-26: Capture's two sections had 26 and 36 pt).
///
/// The link's 44 pt tap target overlaps the space around the row instead of making the row 44 pt tall.
struct SectionHeader: View {
    struct Link {
        let title: String
        let accessibilityLabel: String
        let hint: String
        let action: () -> Void
    }

    /// The gap between a section header and its content.
    static let contentSpacing: CGFloat = Tokens.Spacing.xs

    let label: String
    let link: Link?

    init(_ label: String, link: Link? = nil) {
        self.label = label
        self.link = link
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            SectionLabel(label, size: 12.5)
            Spacer()
            if let link {
                Button(action: link.action) {
                    Text(link.title)
                        .chirpFont(13.5, .semibold)
                        .foregroundStyle(AppColor.accentText)
                        // The hit area (UX audit F11), laid out at the text's own height.
                        .frame(
                            minWidth: Tokens.Metric.minTapTarget, minHeight: Tokens.Metric.minTapTarget,
                            alignment: .trailing
                        )
                        .contentShape(Rectangle())
                        .padding(.vertical, -Tokens.Spacing.s)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(link.accessibilityLabel)
                .accessibilityHint(link.hint)
            }
        }
        .padding(.top, Tokens.Spacing.xxs)
    }
}

/// The look of a compact filled button for a pill that is part of a larger button's label (a card that is itself the
/// button, like Capture's Create card and Record Meeting row): the same font, height and colors as
/// `.chirp(.filled, size: .compact)`, without a second button inside the first.
struct PillLabel: View {
    let title: String
    @ScaledMetric(relativeTo: .subheadline) private var fontSize: CGFloat = 13.5

    var body: some View {
        Text(title)
            .font(.system(size: fontSize, weight: .bold))
            .foregroundStyle(ChirpButtonStyle.Kind.filled.ink(isEnabled: true))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, Tokens.Spacing.m)
            .frame(minHeight: Tokens.Metric.compactButtonHeight)
            .background(Capsule().fill(ChirpButtonStyle.Kind.filled.fill(isEnabled: true)))
    }
}

extension View {
    /// R7-25: content scrolling under the status bar fades out under a `ground` gradient instead of being cut at the
    /// hard edge of a 96% scrim (screens without a navigation bar, where iOS draws no scroll-edge effect of its own).
    func softStatusBarEdge() -> some View {
        safeAreaInset(edge: .top, spacing: 0) {
            Color.clear
                .frame(height: 0)
                .background {
                    // Solid under the status bar (its text stays legible), then a short fade below it.
                    Tokens.Color.ground
                        .ignoresSafeArea(edges: .top)
                        .overlay(alignment: .bottom) {
                            LinearGradient(
                                colors: [Tokens.Color.ground, Tokens.Color.ground.opacity(0)], startPoint: .top,
                                endPoint: .bottom
                            )
                            .frame(height: Tokens.Spacing.m)
                            .offset(y: Tokens.Spacing.m)
                        }
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
        }
    }
}

/// Moves between tabs that share the Library's state.
@MainActor enum LibraryNavigation {
    /// "See all" from Capture's Recent (R6a-14): every item, not the filter or search the Library was left on (the
    /// Transforms tab's "See all in Library" picks Documents).
    static func showEverything(_ library: LibraryViewModel) {
        library.searchText = ""
        library.filter = .all
    }
}
