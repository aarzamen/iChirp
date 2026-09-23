import ChirpUI
import SwiftUI
import UIKit

/// App-level colors derived from `Tokens` for the few surfaces the canvas defines in light mode only.
///
/// The canvas is light-only (spec/04-ui.md). `Tokens` already adapts ground, surface, border, ink and secondary; the
/// tint and quiet fills below would put light fills under light (dark-mode) ink, so in dark mode they fall back to
/// other token values instead of a new palette. No hex literals here: every value comes from `Tokens`.
enum AppColor {
    /// The tint fill (Dictate card, current paragraph, icon tiles).
    static let tintFill = adaptive(light: Tokens.Color.tint, dark: Tokens.Color.accent.opacity(0.16))
    /// The Dictate card's hairline.
    static let tintStroke = adaptive(light: Tokens.Color.tintBorder, dark: Tokens.Color.accent.opacity(0.35))
    /// A selected chip's hairline.
    static let tintStrokeSelected = adaptive(
        light: Tokens.Color.tintBorderSelected, dark: Tokens.Color.accent.opacity(0.5))
    /// Tracks, inactive segments, row separators.
    static let quietFill = adaptive(light: Tokens.Color.quietFill, dark: Tokens.Color.border)
    /// Accent text: accent-ink on the light ground, the brighter accent on the dark ground (contrast).
    static let accentText = adaptive(light: Tokens.Color.accentInk, dark: Tokens.Color.accent)
    /// Accent text specifically on a tint fill — `CapsuleButtonLabel`'s `.tinted` kind (F8): `accentInk` on
    /// `tintFill` measures 4.39:1 in light mode, below 4.5 for 13–13.5pt text. `accentInkPressed` gets about 7:1
    /// without changing the tint fill itself. The dark branch is unchanged from `accentText` today (plan 023, F6
    /// gives dark mode its own palette later).
    static let accentTextOnTint = adaptive(light: Tokens.Color.accentInkPressed, dark: Tokens.Color.accent)
    /// Error text and destructive actions.
    static let error = Tokens.Color.stopRed

    private static func adaptive(light: Color, dark: Color) -> Color {
        let lightColor = UIColor(light)
        let darkColor = UIColor(dark)
        return Color(
            UIColor { traits in
                (traits.userInterfaceStyle == .dark ? darkColor : lightColor).resolvedColor(with: traits)
            })
    }
}

/// A canvas font size that still follows Dynamic Type: `size` is the canvas value at the default text size and
/// scales with the user's setting (relative to a text style picked from the size).
struct ChirpFont: ViewModifier {
    @ScaledMetric private var size: CGFloat
    private let weight: Font.Weight
    private let rounded: Bool

    init(size: CGFloat, weight: Font.Weight, rounded: Bool) {
        _size = ScaledMetric(wrappedValue: size, relativeTo: Self.textStyle(for: size))
        self.weight = weight
        self.rounded = rounded
    }

    func body(content: Content) -> some View {
        content.font(rounded ? Tokens.Font.rounded(size, weight) : .system(size: size, weight: weight))
    }

    static func textStyle(for size: CGFloat) -> Font.TextStyle {
        switch size {
        case 26...: .largeTitle
        case 20..<26: .title2
        case 17..<20: .headline
        case 14.5..<17: .body
        case 12.5..<14.5: .subheadline
        case 11.5..<12.5: .footnote
        default: .caption
        }
    }
}

extension View {
    /// SF Pro at a canvas size, scaled by Dynamic Type.
    func chirpFont(_ size: CGFloat, _ weight: Font.Weight = .regular) -> some View {
        modifier(ChirpFont(size: size, weight: weight, rounded: false))
    }

    /// SF Pro Rounded (`Tokens.Font.rounded`) at a canvas size, scaled by Dynamic Type. For titles.
    func chirpTitleFont(_ size: CGFloat, _ weight: Font.Weight = .bold) -> some View {
        modifier(ChirpFont(size: size, weight: weight, rounded: true))
    }

    /// Keeps scrolled content from showing through the status bar on screens without a navigation bar.
    func statusBarScrim() -> some View {
        safeAreaInset(edge: .top, spacing: 0) {
            Color.clear
                .frame(height: 0)
                .background(Tokens.Color.ground.opacity(0.96), ignoresSafeAreaEdges: .top)
        }
    }
}

/// The small uppercase, tracked section label the canvas uses ("RECENT", "TODAY", "SPEECH").
struct SectionLabel: View {
    let text: String
    var size: CGFloat = 11.5

    init(_ text: String, size: CGFloat = 11.5) {
        self.text = text
        self.size = size
    }

    var body: some View {
        Text(text.uppercased())
            .chirpFont(size, .bold)
            .tracking(size * 0.09)
            .foregroundStyle(Tokens.Color.secondary)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A rounded rectangle filled and stroked with tokens: the canvas's cards, tiles and rows.
struct CardBackground: View {
    var radius: CGFloat
    var fill: Color = Tokens.Color.surface
    var stroke: Color = Tokens.Color.border

    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(fill)
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(stroke, lineWidth: 1)
            )
    }
}

/// A small capsule action button ("Retry", "Download", "Delete", "Start").
struct CapsuleButtonLabel: View {
    enum Kind {
        /// Accent-ink fill, white text (canvas "Start").
        case filled
        /// Tint fill, accent text.
        case tinted
        /// Quiet fill, error text.
        case destructive
    }

    let title: String
    var kind: Kind = .tinted

    var body: some View {
        Text(title)
            .chirpFont(13.5, .bold)
            .foregroundStyle(foreground)
            .padding(.horizontal, 14)
            .frame(minHeight: 32)
            .background(Capsule().fill(background))
            // F7: the visual pill stays 32pt (the canvas size), but the tappable area grows to the 44pt
            // accessibility floor — a frame added *inside* the label, not by callers wrapping the button from the
            // outside (that never enlarges a button's actual hit area).
            .frame(minHeight: 44)
            .contentShape(Rectangle())
    }

    private var foreground: Color {
        switch kind {
        case .filled: .white
        // F8: `accentTextOnTint`, not `accentText` — `accentText` alone fails 4.5:1 on this button's tint
        // background in light mode.
        case .tinted: AppColor.accentTextOnTint
        case .destructive: AppColor.error
        }
    }

    private var background: Color {
        switch kind {
        case .filled: Tokens.Color.accentInk
        case .tinted: AppColor.tintFill
        case .destructive: AppColor.quietFill
        }
    }
}
