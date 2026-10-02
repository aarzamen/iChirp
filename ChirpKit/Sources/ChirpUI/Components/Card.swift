import SwiftUI

/// The one card surface (R7-22, plan 024 Task 11): a rounded rectangle filled with a token and edged with an
/// inset hairline. Use it as a background — `.background(ChirpCardBackground(radius: Tokens.Radius.s))` — for cards,
/// tiles and rows that set their own padding, or through `.chirpCard(...)` below, which adds the padding too.
///
/// It replaces the app's `CardBackground` (same parameters, same inset `strokeBorder`), so the app and ChirpUI draw
/// cards one way: the hairline sits inside the shape and never widens the card or gets clipped.
public struct ChirpCardBackground: View {
    public var radius: CGFloat
    public var fill: Color
    public var stroke: Color

    public init(radius: CGFloat, fill: Color = Tokens.Color.surface, stroke: Color = Tokens.Color.border) {
        self.radius = radius
        self.fill = fill
        self.stroke = stroke
    }

    public var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(fill)
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(stroke, lineWidth: Tokens.Metric.hairline)
            )
    }
}

/// The grouped-surface treatment used everywhere on the canvas: white surface fill, a hairline
/// `Tokens.Color.border`, and a radius token. Apply with the `.chirpCard(...)` view extension
/// below rather than constructing this directly. Drawn with `ChirpCardBackground`.
public struct ChirpCardStyle: ViewModifier {
    public var radius: CGFloat
    public var padding: CGFloat
    public var fill: Color
    public var stroke: Color

    public init(
        radius: CGFloat = Tokens.Radius.m, padding: CGFloat = Tokens.Spacing.m, fill: Color = Tokens.Color.surface,
        stroke: Color = Tokens.Color.border
    ) {
        self.radius = radius
        self.padding = padding
        self.fill = fill
        self.stroke = stroke
    }

    public func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(ChirpCardBackground(radius: radius, fill: fill, stroke: stroke))
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

extension View {
    /// Wraps `self` in the standard ChirpUI card surface: fill, border, radius and padding
    /// from `Tokens`. This is the modifier every grouped card on the canvas (Settings rows,
    /// the Meeting recording card, Dictate's hero card, etc.) should use instead of hand-rolled
    /// background/overlay/clipShape chains.
    public func chirpCard(
        radius: CGFloat = Tokens.Radius.m, padding: CGFloat = Tokens.Spacing.m, fill: Color = Tokens.Color.surface,
        stroke: Color = Tokens.Color.border
    ) -> some View {
        modifier(ChirpCardStyle(radius: radius, padding: padding, fill: fill, stroke: stroke))
    }
}

#Preview("Card") {
    VStack(spacing: Tokens.Spacing.m) {
        VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
            Text("Weekly Sync — Detachment Leads")
                .font(.system(size: 15, weight: .semibold))
            Text("Meeting · 28:40 · 4 speakers")
                .font(.system(size: 12))
                .foregroundStyle(Tokens.Color.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .chirpCard()
        Text("A tint card")
            .frame(maxWidth: .infinity, minHeight: 60)
            .background(
                ChirpCardBackground(radius: Tokens.Radius.l, fill: Tokens.Color.tint, stroke: Tokens.Color.tintBorder))
    }
    .padding(Tokens.Spacing.xl)
    .background(Tokens.Color.ground)
}
