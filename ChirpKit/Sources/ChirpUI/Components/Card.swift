import SwiftUI

/// The grouped-surface treatment used everywhere on the canvas: white surface fill, a hairline
/// `Tokens.Color.border`, and a radius token. Apply with the `.chirpCard(...)` view extension
/// below rather than constructing this directly.
public struct ChirpCardStyle: ViewModifier {
    public var radius: CGFloat
    public var padding: CGFloat
    public var fill: Color

    public init(radius: CGFloat = Tokens.Radius.m, padding: CGFloat = 16, fill: Color = Tokens.Color.surface) {
        self.radius = radius
        self.padding = padding
        self.fill = fill
    }

    public func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(fill)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(Tokens.Color.border, lineWidth: 1)
            )
    }
}

extension View {
    /// Wraps `self` in the standard ChirpUI card surface: fill, border, radius and padding
    /// from `Tokens`. This is the modifier every grouped card on the canvas (Settings rows,
    /// the Meeting recording card, Dictate's hero card, etc.) should use instead of hand-rolled
    /// background/overlay/clipShape chains.
    public func chirpCard(radius: CGFloat = Tokens.Radius.m, padding: CGFloat = 16, fill: Color = Tokens.Color.surface)
        -> some View
    {
        modifier(ChirpCardStyle(radius: radius, padding: padding, fill: fill))
    }
}

#Preview("Card") {
    VStack(alignment: .leading, spacing: 8) {
        Text("Weekly Sync — Detachment Leads")
            .font(.system(size: 15, weight: .semibold))
        Text("Meeting · 28:40 · 4 speakers")
            .font(.system(size: 12))
            .foregroundStyle(Tokens.Color.secondary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .chirpCard()
    .padding(24)
    .background(Tokens.Color.ground)
}
