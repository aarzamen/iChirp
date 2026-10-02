import SwiftUI

/// SF Symbol glyphs and fixed frames that follow Dynamic Type (R7-4, plan 024 Task 11).
///
/// About 55 glyphs in the app were `.font(.system(size: 19))` and stayed 19 pt beside labels that doubled at the
/// accessibility sizes; the Parakeet mark and icon tiles had fixed frames. These modifiers take the canvas size and
/// scale it with `@ScaledMetric`, relative to the text style a canvas size of that height scales by
/// (`Tokens.Font.textStyle(forCanvasSize:)`, the same table as the app's `chirpFont`), so a glyph grows at the rate of
/// the label beside it. `maxScale` stops a glyph or frame short of body text's growth where it must stay in a bar or
/// row (the action bar's icons stop at 1.6×).
struct ChirpScaledGlyph: ViewModifier {
    @ScaledMetric private var size: CGFloat
    private let base: CGFloat
    private let weight: SwiftUI.Font.Weight
    private let design: SwiftUI.Font.Design
    private let maxScale: CGFloat?

    init(
        size: CGFloat, weight: SwiftUI.Font.Weight, design: SwiftUI.Font.Design, relativeTo: SwiftUI.Font.TextStyle?,
        maxScale: CGFloat?
    ) {
        _size = ScaledMetric(
            wrappedValue: size, relativeTo: relativeTo ?? Tokens.Font.textStyle(forCanvasSize: size))
        base = size
        self.weight = weight
        self.design = design
        self.maxScale = maxScale
    }

    func body(content: Content) -> some View {
        content.font(
            .system(
                size: Tokens.Scale.capped(size, base: base, maxScale: maxScale), weight: weight, design: design))
    }
}

/// A fixed `width × height` frame (the Parakeet mark, an icon tile, a dot) that grows with Dynamic Type.
struct ChirpScaledFrame: ViewModifier {
    @ScaledMetric private var width: CGFloat
    @ScaledMetric private var height: CGFloat
    private let baseWidth: CGFloat
    private let baseHeight: CGFloat
    private let maxScale: CGFloat?
    private let alignment: Alignment

    init(width: CGFloat, height: CGFloat, relativeTo: SwiftUI.Font.TextStyle, maxScale: CGFloat?, alignment: Alignment)
    {
        _width = ScaledMetric(wrappedValue: width, relativeTo: relativeTo)
        _height = ScaledMetric(wrappedValue: height, relativeTo: relativeTo)
        baseWidth = width
        baseHeight = height
        self.maxScale = maxScale
        self.alignment = alignment
    }

    func body(content: Content) -> some View {
        content.frame(
            width: Tokens.Scale.capped(width, base: baseWidth, maxScale: maxScale),
            height: Tokens.Scale.capped(height, base: baseHeight, maxScale: maxScale),
            alignment: alignment)
    }
}

extension View {
    /// A glyph (usually an SF Symbol `Image`) at a canvas point size that follows Dynamic Type. Use instead of
    /// `.font(.system(size:weight:))` on icons: `Image(systemName: "sparkles").chirpGlyph(19, .medium)`.
    ///
    /// - Parameters:
    ///   - size: the canvas size at the default text size.
    ///   - relativeTo: the text style to scale with; by default the one a canvas size of `size` maps to.
    ///   - maxScale: the most it may grow, as a multiple of `size` (`nil`: as far as the text style does).
    public func chirpGlyph(
        _ size: CGFloat, _ weight: SwiftUI.Font.Weight = .regular, design: SwiftUI.Font.Design = .default,
        relativeTo: SwiftUI.Font.TextStyle? = nil, maxScale: CGFloat? = nil
    ) -> some View {
        modifier(
            ChirpScaledGlyph(size: size, weight: weight, design: design, relativeTo: relativeTo, maxScale: maxScale))
    }

    /// A fixed frame that follows Dynamic Type: `ParakeetMarkView().chirpScaledFrame(width: 24, height: 24,
    /// relativeTo: .title2)` keeps the mark at the wordmark's size as the wordmark grows.
    public func chirpScaledFrame(
        width: CGFloat, height: CGFloat, relativeTo: SwiftUI.Font.TextStyle = .body, maxScale: CGFloat? = nil,
        alignment: Alignment = .center
    ) -> some View {
        modifier(
            ChirpScaledFrame(
                width: width, height: height, relativeTo: relativeTo, maxScale: maxScale, alignment: alignment))
    }
}
