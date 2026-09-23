import ChirpUI
import SwiftUI

/// App-level names for `Tokens` colors, kept so screens read by role ("accent text", "error").
///
/// Every token now carries its own light, dark and Increase Contrast values (plan 023, F6: `Tokens.Palette`), so
/// these are plain aliases: no opacity blends and no per-screen dark branches. No hex literals here.
enum AppColor {
    /// The tint fill (Create card, current paragraph, icon tiles, selected chips). A deep warm tint in dark mode.
    static let tintFill = Tokens.Color.tint
    /// The tint card's hairline.
    static let tintStroke = Tokens.Color.tintBorder
    /// A selected chip's hairline.
    static let tintStrokeSelected = Tokens.Color.tintBorderSelected
    /// Tracks, inactive segments, row separators, quiet chips.
    static let quietFill = Tokens.Color.quietFill
    /// Accent text and links: text-safe on ground and surface in every appearance.
    static let accentText = Tokens.Color.accentInk
    /// Accent text on a tint fill — `CapsuleButtonLabel`'s `.tinted` kind (F8): about 7:1 on `tintFill` in light
    /// mode (plain `accentInk` is 4.39:1 there) and 7.5:1 in dark mode.
    static let accentTextOnTint = Tokens.Color.accentInkPressed
    /// Error text and glyphs. A destructive *fill* (swipe action, Stop & save) reads `Tokens.Color.stopRed`, since
    /// dark mode's error text is a light red that a white label could not sit on.
    static let error = Tokens.Color.errorInk
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
        /// Accent fill, white text (canvas "Start").
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
        case .filled: Tokens.Color.onAccent
        // F8: `accentTextOnTint`, not `accentText` — `accentText` alone fails 4.5:1 on this button's tint
        // background in light mode.
        case .tinted: AppColor.accentTextOnTint
        case .destructive: AppColor.error
        }
    }

    private var background: Color {
        switch kind {
        case .filled: Tokens.Color.accentFill
        case .tinted: AppColor.tintFill
        case .destructive: AppColor.quietFill
        }
    }
}
