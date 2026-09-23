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
public enum Tokens {

    public enum Color {

        // MARK: Brand — identical in light and dark mode

        public static let accent = hex(0xE86B3B)
        /// Icon/fill ink; in light mode it is `contrastAwareLight`-boosted under Increase Contrast (F5). Text on
        /// `tint`/`surface` should prefer `accentInkPressed` directly (see `successInk` below for the same idea
        /// applied to `success`).
        public static let accentInk = contrastAwareLight(base: 0xBE4E26, highContrastLight: 0x8F3A1B)
        /// Hover/pressed state for `accentInk`. Also the text-safe ink to pair with `tint`/light fills (F8): about
        /// 7:1 on `tint`, versus `accentInk`'s 4.39:1.
        public static let accentInkPressed = hex(0x8F3A1B)
        public static let tint = hex(0xFFF0EB)
        /// Icon and dot-fill green only — **3.06:1 as text on `surface`, below 4.5:1 (F4).** Text that reads this
        /// color (a caption, a status line) must use `successInk` instead.
        public static let success = hex(0x33A854)
        /// Text-safe green: 5.3:1 on `surface`/white in light mode, the same hex `privacyBadgeInk` already uses.
        /// The dark branch matches `success` as rendered today (identical in both modes), so this token changes
        /// nothing in dark mode; the owner's dark palette (plan 023, F6) can give it its own dark value later
        /// without touching call sites.
        public static let successInk = adaptive(light: 0x1E7B4A, dark: 0x33A854)
        public static let rosette = hex(0x59A659)
        public static let recordRed = hex(0xE64D42)
        public static let stopRed = hex(0xC9342B)
        public static let night = hex(0x141417)
        public static let coverNight = hex(0x16211D)
        public static let favorite = hex(0xF5A623)

        // MARK: Surfaces — adaptive (light canvas value, sensible dark variant)

        /// The canvas is light-only; these five give every surface color a dark-mode
        /// counterpart via `UIColor`'s dynamic-provider initializer on iOS. On macOS (no
        /// UIKit) they fall back to the plain light value from the canvas.
        public static let ground = adaptive(light: 0xFAFAF7, dark: 0x121212)
        public static let surface = adaptive(light: 0xFFFFFF, dark: 0x1E1E20)
        /// Increase Contrast (light mode only, F5): `#BDBDB5` instead of the canvas `#E8E8E0` hairline.
        public static let border = adaptive(light: 0xE8E8E0, dark: 0x333335, highContrastLight: 0xBDBDB5)
        public static let ink = adaptive(light: 0x1A1A1A, dark: 0xF2F2F0)
        /// Increase Contrast (light mode only, F5): `#4F4F4F` instead of the canvas `#6B6B6B`.
        public static let secondary = adaptive(light: 0x6B6B6B, dark: 0x9A9A9A, highContrastLight: 0x4F4F4F)

        // MARK: Supporting values seen in the artboards (named, not scattered literals)

        public static let tintBorder = hex(0xF6D3C3)
        public static let tintBorderSelected = hex(0xF1C9B6)
        public static let quietFill = hex(0xF0F0E8)
        /// Icon/placeholder fill only — **2.75:1 as text on `surface`, below 4.5:1 (F4).** Text that reads this
        /// color must use `secondary` instead (5.10:1). Under Increase Contrast in light mode (F5) this itself
        /// steps up to `secondary`'s light value, since a muted icon should never out-contrast the text beside it.
        public static let mutedText = contrastAwareLight(base: 0x9C9C9C, highContrastLight: 0x6B6B6B)
        public static let toggleOffTrack = hex(0xDDDDD5)
        public static let partialAudioFill = hex(0xFDF3DF)
        public static let partialAudioInk = hex(0x8A5A00)
        public static let privacyBadgeFill = hex(0xE8F5EC)
        public static let privacyBadgeInk = hex(0x1E7B4A)
        public static let seedStrokeDim = hex(0x6E8F7A)
        public static let seedStrokeBright = hex(0x9DBFA8)
        public static let dictationAccent = hex(0xFF8A5C)

        /// Speaker dot / label-ink pairs, in palette order: blue, purple, green, amber.
        public static let speakers: [(dot: SwiftUI.Color, ink: SwiftUI.Color)] = [
            (hex(0x3382D6), hex(0x2A6CB5)),
            (hex(0xB854A3), hex(0x9A3F87)),
            (hex(0x299975), hex(0x1E7B5D)),
            (hex(0xD18524), hex(0x8F5A12)),
        ]

        /// The speaker palette entry for `index`, wrapping modulo the palette length so any
        /// speaker count (by order of first speech) cycles the four colors instead of running
        /// out. Handles negative indices too.
        public static func speaker(at index: Int) -> (dot: SwiftUI.Color, ink: SwiftUI.Color) {
            let count = speakers.count
            let wrapped = ((index % count) + count) % count
            return speakers[wrapped]
        }

        /// Pure `0xRRGGBB` -> unit-interval RGB component parser. No SwiftUI/UIKit dependency,
        /// so it can be copied into a standalone `swift` script and verified without building
        /// the package (see `README.md`'s "How to verify").
        public static func rgbComponents(fromHex value: UInt32) -> (red: Double, green: Double, blue: Double) {
            let red = Double((value >> 16) & 0xFF) / 255.0
            let green = Double((value >> 8) & 0xFF) / 255.0
            let blue = Double(value & 0xFF) / 255.0
            return (red, green, blue)
        }

        /// Builds a `SwiftUI.Color` from a `0xRRGGBB` literal via `rgbComponents(fromHex:)`.
        public static func hex(_ value: UInt32) -> SwiftUI.Color {
            let components = rgbComponents(fromHex: value)
            return SwiftUI.Color(red: components.red, green: components.green, blue: components.blue)
        }

        /// A color that reads `light` in light mode and `dark` in dark mode on iOS/UIKit platforms, or plainly
        /// `light` where UIKit isn't available (macOS). When `highContrastLight` is given, light mode reads it
        /// instead of `light` while the system's Increase Contrast setting is on (F5); dark mode is never affected
        /// by the contrast trait — the owner's dark palette (plan 023, F6) is a separate, later change.
        private static func adaptive(
            light: UInt32, dark: UInt32, highContrastLight: UInt32? = nil
        ) -> SwiftUI.Color {
            #if canImport(UIKit)
            return SwiftUI.Color(
                UIColor { traits in
                    let value: UInt32
                    if traits.userInterfaceStyle == .dark {
                        value = dark
                    } else if traits.accessibilityContrast == .high, let highContrastLight {
                        value = highContrastLight
                    } else {
                        value = light
                    }
                    let components = rgbComponents(fromHex: value)
                    return UIColor(red: components.red, green: components.green, blue: components.blue, alpha: 1)
                })
            #else
            return hex(light)
            #endif
        }

        /// A brand color that is the same hex in light and dark mode today (like every non-surface token; see the
        /// module README), except that light mode swaps to `highContrastLight` while Increase Contrast is on (F5).
        /// Dark mode always reads `base`, whatever the contrast trait, until the owner's dark palette (plan 023,
        /// F6) gives it its own values.
        private static func contrastAwareLight(base: UInt32, highContrastLight: UInt32) -> SwiftUI.Color {
            #if canImport(UIKit)
            return SwiftUI.Color(
                UIColor { traits in
                    let value =
                        (traits.userInterfaceStyle != .dark && traits.accessibilityContrast == .high)
                        ? highContrastLight : base
                    let components = rgbComponents(fromHex: value)
                    return UIColor(red: components.red, green: components.green, blue: components.blue, alpha: 1)
                })
            #else
            return hex(base)
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
