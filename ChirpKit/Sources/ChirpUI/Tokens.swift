import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

/// Design tokens for Parakeet's ChirpUI: colors, radii and rounded type.
///
/// These are the single source of truth for values sourced from the owner's design canvas
/// (`docs/design/2026-09-21-iphone-canvas/*.dc.html`) and the design handoff
/// (`docs/plans/2026-09-22-001-feat-iphone-app-design-handoff.md`). Screens and components
/// read colors, radii and type from here — never hardcode a hex literal in `App/`.
///
/// Colors live in two layers: `Tokens.Palette` holds each token's hex in all four appearances (light, dark, and each
/// with the system's Increase Contrast setting) as plain numbers, and `Tokens.Color` turns those into SwiftUI colors
/// that follow the appearance on iOS. `ContrastTests` reads `Tokens.Palette` directly, so every number below is
/// checked against WCAG 2.1 (4.5:1 text, 3:1 large text and UI glyphs) in every appearance.
public enum Tokens {

    // MARK: - Appearances and color values

    /// The four appearances a color is drawn in: the system's Light or Dark mode, each with or without Settings →
    /// Accessibility → Display & Text Size → Increase Contrast.
    public enum Appearance: String, CaseIterable, Sendable {
        case light
        case dark
        case lightHighContrast
        case darkHighContrast

        public var isDark: Bool { self == .dark || self == .darkHighContrast }
        public var isHighContrast: Bool { self == .lightHighContrast || self == .darkHighContrast }
    }

    /// One color token's `0xRRGGBB` value in each `Appearance`. The Increase Contrast values default to the ordinary
    /// ones when a token does not need a stronger variant.
    public struct ColorValue: Sendable, Hashable {
        public let light: UInt32
        public let dark: UInt32
        public let lightHighContrast: UInt32
        public let darkHighContrast: UInt32

        public init(light: UInt32, dark: UInt32, lightHighContrast: UInt32? = nil, darkHighContrast: UInt32? = nil) {
            self.light = light
            self.dark = dark
            self.lightHighContrast = lightHighContrast ?? light
            self.darkHighContrast = darkHighContrast ?? dark
        }

        /// A color that is the same in every appearance (the night surfaces of screens that are dark by design).
        public static func fixed(_ value: UInt32) -> ColorValue {
            ColorValue(light: value, dark: value)
        }

        /// The hex this token draws in `appearance`.
        public func hex(in appearance: Appearance) -> UInt32 {
            switch appearance {
            case .light: light
            case .dark: dark
            case .lightHighContrast: lightHighContrast
            case .darkHighContrast: darkHighContrast
            }
        }
    }

    // MARK: - Palette (plan 023, F6)

    /// Every color token as numbers. Light values are the owner's canvas (unchanged); dark values are the plan 023
    /// (ux-audit-2b9ad612 F6) dark palette: warm near-black surfaces instead of pure black, the coral, greens and
    /// speaker colors desaturated and lifted just enough to read on them without glare, and pills as deep tinted
    /// fills rather than light patches. Increase Contrast values step every text and glyph color further from its
    /// background in both schemes (F5, extended to dark mode).
    ///
    /// "Text" below means WCAG 4.5:1 against every background it is drawn on; "glyph" means 3:1 (icons, dots,
    /// fills whose shape carries meaning, and the white glyph on them). `ContrastTests` holds the table of pairs.
    public enum Palette {

        // MARK: Surfaces

        /// Screen background: warm off-white (canvas), warm near-black in dark mode.
        public static let ground = ColorValue(light: 0xFAFAF7, dark: 0x15120F)
        /// Cards and rows: white, one warm step above `ground` in dark mode.
        public static let surface = ColorValue(light: 0xFFFFFF, dark: 0x1F1B18)
        /// Hairlines around cards and rows. Increase Contrast makes them clearly visible (F5).
        public static let border = ColorValue(
            light: 0xE8E8E0, dark: 0x38322D, lightHighContrast: 0xBDBDB5, darkHighContrast: 0x6A625A)
        /// Tracks, inactive segments, quiet chips and separators.
        public static let quietFill = ColorValue(light: 0xF0F0E8, dark: 0x2A2521)
        /// A switch's off track.
        public static let toggleOffTrack = ColorValue(
            light: 0xDDDDD5, dark: 0x3E3833, lightHighContrast: 0xC8C8BF, darkHighContrast: 0x5A534D)

        // MARK: Text

        /// Primary text. Warm off-white in dark mode (not pure white, which glares at night).
        public static let ink = ColorValue(light: 0x1A1A1A, dark: 0xEFE9E2, darkHighContrast: 0xFBF8F4)
        /// Secondary text and meta. Text-safe on ground, surface, quiet and tint fills.
        public static let secondary = ColorValue(
            light: 0x6B6B6B, dark: 0xA69E96, lightHighContrast: 0x4F4F4F, darkHighContrast: 0xCFC8C0)
        /// Icons, chevrons and placeholders only — not text (use `secondary`). The canvas light value is 2.75:1 on
        /// `surface` (below 3:1, see `ContrastTests`' documented canvas exceptions); every other appearance is at
        /// least 3:1 as a glyph.
        public static let mutedText = ColorValue(
            light: 0x9C9C9C, dark: 0x857C74, lightHighContrast: 0x6B6B6B, darkHighContrast: 0xA69E96)

        // MARK: Accent (coral)

        /// The brand coral, for fills and glyphs: the Create circle, Play, progress, the selected tab underline.
        /// Carries a white glyph (3:1). Slightly desaturated in dark mode so a large coral circle does not glare.
        public static let accent = ColorValue(light: 0xE86B3B, dark: 0xD9673F, lightHighContrast: 0xC2562D)
        /// Accent text and links (the app-wide tint). Text-safe on ground and surface; a light coral in dark mode.
        public static let accentInk = ColorValue(
            light: 0xBE4E26, dark: 0xF0916A, lightHighContrast: 0x8F3A1B, darkHighContrast: 0xFFB28F)
        /// Hover/pressed state for `accentInk`, and the text-safe accent on `tint` fills (F8): about 7:1 there.
        public static let accentInkPressed = ColorValue(
            light: 0x8F3A1B, dark: 0xF7A57F, lightHighContrast: 0x7A3016, darkHighContrast: 0xFFC4A8)
        /// Filled buttons with a white label (Start, Done, Hide, Edit by voice, Create): 4.5:1 or more for the label
        /// in every appearance. The light value is the canvas's accent-ink fill; dark mode uses a deeper terracotta.
        public static let accentFill = ColorValue(
            light: 0xBE4E26, dark: 0xB34E2D, lightHighContrast: 0x8F3A1B, darkHighContrast: 0xA04528)
        /// The label or glyph on `accentFill`, `accent`, `stopRed`, `recordRed`, `success` and `night` fills.
        public static let onAccent = ColorValue.fixed(0xFFFFFF)
        /// Selected chips, the Create card, the current transcript paragraph, icon tiles. A deep warm tint (not a
        /// light patch) in dark mode.
        public static let tint = ColorValue(light: 0xFFF0EB, dark: 0x36241C)
        /// The hairline around a tint card.
        public static let tintBorder = ColorValue(
            light: 0xF6D3C3, dark: 0x5A3A2C, lightHighContrast: 0xE3A88C, darkHighContrast: 0x8A5A45)
        /// The hairline around a selected chip.
        public static let tintBorderSelected = ColorValue(
            light: 0xF1C9B6, dark: 0x7C4B36, lightHighContrast: 0xD98F6E, darkHighContrast: 0xA8705A)

        // MARK: Status

        /// "On" switches, ready dots, check glyphs — a glyph color, not text (use `successInk`).
        public static let success = ColorValue(light: 0x33A854, dark: 0x3E9F5A, lightHighContrast: 0x23813F)
        /// Text-safe green.
        public static let successInk = ColorValue(
            light: 0x1E7B4A, dark: 0x72CE8E, lightHighContrast: 0x155E38, darkHighContrast: 0x9BE3B0)
        /// Error text and glyphs ("Nothing was sent", destructive capsule labels). A light red in dark mode.
        public static let errorInk = ColorValue(
            light: 0xC9342B, dark: 0xF2857A, lightHighContrast: 0xA3241D, darkHighContrast: 0xFFB0A6)
        /// The Stop & save fill and destructive swipe actions, with a white label (4.5:1).
        public static let stopRed = ColorValue(
            light: 0xC9342B, dark: 0xBA3A30, lightHighContrast: 0xA3241D, darkHighContrast: 0xA8322A)
        /// The recording dot and the listening circle (white glyph, 3:1).
        public static let recordRed = ColorValue(light: 0xE64D42, dark: 0xE0574C, lightHighContrast: 0xC7362C)
        /// The favorite star. Canvas light value is 2.03:1 on white (documented canvas exception).
        public static let favorite = ColorValue(light: 0xF5A623, dark: 0xE8A23C, lightHighContrast: 0xA86E00)
        /// The Meeting rosette (brand mark, decorative).
        public static let rosette = ColorValue(light: 0x59A659, dark: 0x63B067, lightHighContrast: 0x3F8A43)

        // MARK: Pills

        /// "Runs on this iPhone" / on-device badge fill: pale green, deep green in dark mode (no glare).
        public static let privacyBadgeFill = ColorValue(light: 0xE8F5EC, dark: 0x183022)
        /// Text on `privacyBadgeFill` (and on `surface`, "Clean text on copy").
        public static let privacyBadgeInk = ColorValue(
            light: 0x1E7B4A, dark: 0x80D89C, lightHighContrast: 0x155E38, darkHighContrast: 0xA6E8BA)
        /// "Partial audio" / STUB / Draft badge fill: pale amber, deep amber in dark mode.
        public static let partialAudioFill = ColorValue(light: 0xFDF3DF, dark: 0x352812)
        /// Text on `partialAudioFill`.
        public static let partialAudioInk = ColorValue(
            light: 0x8A5A00, dark: 0xF0C36A, lightHighContrast: 0x6B4500, darkHighContrast: 0xF7D58F)

        // MARK: Dark by design (the same in every appearance)

        /// The Dictating screen and dictation Live Activity background.
        public static let night = ColorValue.fixed(0x141417)
        /// The Seed-of-Life meeting cover field.
        public static let coverNight = ColorValue.fixed(0x16211D)
        public static let seedStrokeDim = ColorValue.fixed(0x6E8F7A)
        public static let seedStrokeBright = ColorValue.fixed(0x9DBFA8)
        /// Coral text, caret and waveform on `night`.
        public static let dictationAccent = ColorValue.fixed(0xFF8A5C)

        // MARK: Speakers

        /// Speaker dot / label-ink pairs, in palette order: blue, purple, green, amber. Inks are text-safe on
        /// ground, surface and tint (the current paragraph) in every appearance; the four stay clearly distinct
        /// (`ContrastTests` checks a CIE76 color difference of 25 or more between any two).
        public static let speakers: [(dot: ColorValue, ink: ColorValue)] = [
            (
                ColorValue(light: 0x3382D6, dark: 0x4F97E3),
                ColorValue(light: 0x2A6CB5, dark: 0x7FB3EE, lightHighContrast: 0x1F5694, darkHighContrast: 0xA9CDF6)
            ),
            (
                ColorValue(light: 0xB854A3, dark: 0xC271B2),
                ColorValue(light: 0x9A3F87, dark: 0xD791C9, lightHighContrast: 0x7B2F6C, darkHighContrast: 0xE9B5DE)
            ),
            (
                ColorValue(light: 0x299975, dark: 0x35AE85),
                ColorValue(light: 0x1E7B5D, dark: 0x5CC9A0, lightHighContrast: 0x155E46, darkHighContrast: 0x8FDDBF)
            ),
            (
                ColorValue(light: 0xD18524, dark: 0xD8963A, lightHighContrast: 0xB0701A),
                ColorValue(light: 0x8F5A12, dark: 0xE3A857, lightHighContrast: 0x6B430A, darkHighContrast: 0xF0C68A)
            ),
        ]

        /// Every named token (speakers excluded), for `ContrastTests`' coverage check and the palette table in
        /// `spec/04-ui.md`.
        public static let named: [(name: String, value: ColorValue)] = [
            ("ground", ground), ("surface", surface), ("border", border), ("quietFill", quietFill),
            ("toggleOffTrack", toggleOffTrack), ("ink", ink), ("secondary", secondary), ("mutedText", mutedText),
            ("accent", accent), ("accentInk", accentInk), ("accentInkPressed", accentInkPressed),
            ("accentFill", accentFill), ("onAccent", onAccent), ("tint", tint), ("tintBorder", tintBorder),
            ("tintBorderSelected", tintBorderSelected), ("success", success), ("successInk", successInk),
            ("errorInk", errorInk), ("stopRed", stopRed), ("recordRed", recordRed), ("favorite", favorite),
            ("rosette", rosette), ("privacyBadgeFill", privacyBadgeFill), ("privacyBadgeInk", privacyBadgeInk),
            ("partialAudioFill", partialAudioFill), ("partialAudioInk", partialAudioInk), ("night", night),
            ("coverNight", coverNight), ("seedStrokeDim", seedStrokeDim), ("seedStrokeBright", seedStrokeBright),
            ("dictationAccent", dictationAccent),
        ]
    }

    // MARK: - SwiftUI colors

    public enum Color {

        // MARK: Surfaces

        public static let ground = color(Palette.ground)
        public static let surface = color(Palette.surface)
        public static let border = color(Palette.border)
        public static let quietFill = color(Palette.quietFill)
        public static let toggleOffTrack = color(Palette.toggleOffTrack)

        // MARK: Text

        public static let ink = color(Palette.ink)
        public static let secondary = color(Palette.secondary)
        /// Icon/placeholder fill only — **not text** (F4); text reads `secondary`. See `Palette.mutedText`.
        public static let mutedText = color(Palette.mutedText)

        // MARK: Accent

        /// Brand coral for fills and glyphs (white glyph on it). See `Palette.accent`.
        public static let accent = color(Palette.accent)
        /// Accent text and links; text-safe on ground and surface in every appearance.
        public static let accentInk = color(Palette.accentInk)
        /// Hover/pressed `accentInk`, and the text-safe accent on `tint` (F8).
        public static let accentInkPressed = color(Palette.accentInkPressed)
        /// Filled buttons with a white label. Not the same as `accentInk` in dark mode, where accent *text* is a
        /// light coral that a white label could not sit on.
        public static let accentFill = color(Palette.accentFill)
        /// White: the label or glyph on accent, accent-fill, red, green and night fills.
        public static let onAccent = color(Palette.onAccent)
        public static let tint = color(Palette.tint)
        public static let tintBorder = color(Palette.tintBorder)
        public static let tintBorderSelected = color(Palette.tintBorderSelected)

        // MARK: Status

        /// Icon and dot-fill green only — **3.06:1 as text on `surface`, below 4.5:1 (F4).** Text reads
        /// `successInk`.
        public static let success = color(Palette.success)
        /// Text-safe green in every appearance.
        public static let successInk = color(Palette.successInk)
        /// Error text and glyphs. Fills (a destructive swipe action, Stop & save) read `stopRed` instead.
        public static let errorInk = color(Palette.errorInk)
        public static let stopRed = color(Palette.stopRed)
        public static let recordRed = color(Palette.recordRed)
        public static let favorite = color(Palette.favorite)
        public static let rosette = color(Palette.rosette)

        // MARK: Pills

        public static let privacyBadgeFill = color(Palette.privacyBadgeFill)
        public static let privacyBadgeInk = color(Palette.privacyBadgeInk)
        public static let partialAudioFill = color(Palette.partialAudioFill)
        public static let partialAudioInk = color(Palette.partialAudioInk)

        // MARK: Dark by design

        public static let night = color(Palette.night)
        public static let coverNight = color(Palette.coverNight)
        public static let seedStrokeDim = color(Palette.seedStrokeDim)
        public static let seedStrokeBright = color(Palette.seedStrokeBright)
        public static let dictationAccent = color(Palette.dictationAccent)

        // MARK: Speakers

        /// Speaker dot / label-ink pairs, in palette order: blue, purple, green, amber.
        public static let speakers: [(dot: SwiftUI.Color, ink: SwiftUI.Color)] = Palette.speakers.map {
            (color($0.dot), color($0.ink))
        }

        /// The speaker palette entry for `index`, wrapping modulo the palette length so any
        /// speaker count (by order of first speech) cycles the four colors instead of running
        /// out. Handles negative indices too.
        public static func speaker(at index: Int) -> (dot: SwiftUI.Color, ink: SwiftUI.Color) {
            let count = speakers.count
            let wrapped = ((index % count) + count) % count
            return speakers[wrapped]
        }

        // MARK: Building colors

        /// Pure `0xRRGGBB` -> unit-interval RGB component parser. No SwiftUI/UIKit dependency,
        /// so it can be copied into a standalone `swift` script and verified without building
        /// the package (see `README.md`'s "How to verify").
        public static func rgbComponents(fromHex value: UInt32) -> (red: Double, green: Double, blue: Double) {
            let red = Double((value >> 16) & 0xFF) / 255.0
            let green = Double((value >> 8) & 0xFF) / 255.0
            let blue = Double(value & 0xFF) / 255.0
            return (red, green, blue)
        }

        /// Builds a fixed `SwiftUI.Color` from a `0xRRGGBB` literal via `rgbComponents(fromHex:)`.
        public static func hex(_ value: UInt32) -> SwiftUI.Color {
            let components = rgbComponents(fromHex: value)
            return SwiftUI.Color(red: components.red, green: components.green, blue: components.blue)
        }

        /// A color that follows the appearance on iOS: Light or Dark mode (`userInterfaceStyle`), each with or
        /// without Increase Contrast (`accessibilityContrast == .high`). A view that forces a scheme
        /// (`.preferredColorScheme(.dark)`, the Dictating screen) resolves to that scheme's values. On macOS (no
        /// UIKit dynamic provider) it is the plain light value.
        public static func color(_ value: ColorValue) -> SwiftUI.Color {
            #if canImport(UIKit)
            return SwiftUI.Color(
                UIColor { traits in
                    let appearance: Appearance =
                        switch (traits.userInterfaceStyle == .dark, traits.accessibilityContrast == .high) {
                        case (false, false): .light
                        case (true, false): .dark
                        case (false, true): .lightHighContrast
                        case (true, true): .darkHighContrast
                        }
                    let components = rgbComponents(fromHex: value.hex(in: appearance))
                    return UIColor(red: components.red, green: components.green, blue: components.blue, alpha: 1)
                })
            #else
            return hex(value.light)
            #endif
        }
    }

    public enum Radius {
        public static let s: CGFloat = 14
        public static let m: CGFloat = 16
        public static let l: CGFloat = 20
        public static let xl: CGFloat = 24

        // Supporting radii seen on the canvas — named rather than scattered literals.
        /// Capture's "Paste a link" / "Import audio" tiles.
        public static let tile: CGFloat = 18
        /// Library row covers (52pt).
        public static let cover: CGFloat = 12
        /// Capture "Recent" row covers (40pt).
        public static let coverSmall: CGFloat = 11
        /// 34pt icon tiles inside Capture's tiles.
        public static let iconTile: CGFloat = 10
    }

    public enum Font {
        /// SF Pro Rounded (falls back to the platform's rounded system design) at `size` /
        /// `weight`, used for headline and title text across the app.
        public static func rounded(_ size: CGFloat, _ weight: SwiftUI.Font.Weight = .bold) -> SwiftUI.Font {
            .system(size: size, weight: weight, design: .rounded)
        }
    }
}
