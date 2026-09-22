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
        public static let accentInk = hex(0xBE4E26)
        /// Hover/pressed state for `accentInk`.
        public static let accentInkPressed = hex(0x8F3A1B)
        public static let tint = hex(0xFFF0EB)
        public static let success = hex(0x33A854)
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
        public static let border = adaptive(light: 0xE8E8E0, dark: 0x333335)
        public static let ink = adaptive(light: 0x1A1A1A, dark: 0xF2F2F0)
        public static let secondary = adaptive(light: 0x6B6B6B, dark: 0x9A9A9A)

        // MARK: Supporting values seen in the artboards (named, not scattered literals)

        public static let tintBorder = hex(0xF6D3C3)
        public static let tintBorderSelected = hex(0xF1C9B6)
        public static let quietFill = hex(0xF0F0E8)
        public static let mutedText = hex(0x9C9C9C)
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

        /// A color that reads `light` in light mode and `dark` in dark mode on iOS/UIKit
        /// platforms, or plainly `light` where UIKit isn't available (macOS).
        private static func adaptive(light: UInt32, dark: UInt32) -> SwiftUI.Color {
            #if canImport(UIKit)
            return SwiftUI.Color(
                UIColor { traits in
                    let value = traits.userInterfaceStyle == .dark ? dark : light
                    let components = rgbComponents(fromHex: value)
                    return UIColor(red: components.red, green: components.green, blue: components.blue, alpha: 1)
                })
            #else
            return hex(light)
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
