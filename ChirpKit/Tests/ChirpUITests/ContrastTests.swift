// WCAG contrast checks for the whole palette (plan 023, F6; first added by polish lane u1-design for F4/F5/F8).
//
// Every text and glyph color is measured against every background it is drawn on, in all four appearances (light,
// dark, and each with Increase Contrast), straight from `Tokens.Palette`'s numbers — so a future edit to a hex in
// `Tokens.swift` trips a test instead of waiting for another manual audit. Pure math, no UIKit: this runs with a plain
// `swift test --package-path ChirpKit`, no simulator needed.
//
// The pair table below mirrors the call sites (which foreground token sits on which background). When a screen puts
// a token on a new background, add the pair here. There are no exceptions: on 2026-09-23 the owner had the last five
// below-3:1 canvas glyph colors strengthened and the Dictating screen's tentative text raised to 46% (plan 023 F6).

import XCTest

@testable import ChirpUI

final class ContrastTests: XCTestCase {

    private typealias Appearance = Tokens.Appearance
    private typealias ColorValue = Tokens.ColorValue
    private typealias P = Tokens.Palette

    // MARK: - WCAG 2.1 contrast math

    /// Relative luminance of one sRGB channel in `[0, 1]` (WCAG 2.1 §1.4.3 formula).
    private static func linearize(_ channel: Double) -> Double {
        channel <= 0.03928 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
    }

    /// WCAG relative luminance of a `0xRRGGBB` color.
    private static func luminance(_ hex: UInt32) -> Double {
        let components = Tokens.Color.rgbComponents(fromHex: hex)
        return 0.2126 * linearize(components.red) + 0.7152 * linearize(components.green)
            + 0.0722 * linearize(components.blue)
    }

    /// The WCAG contrast ratio between two `0xRRGGBB` colors, always `>= 1`.
    private static func contrastRatio(_ a: UInt32, _ b: UInt32) -> Double {
        let (l1, l2) = (luminance(a), luminance(b))
        let (lighter, darker) = l1 >= l2 ? (l1, l2) : (l2, l1)
        return (lighter + 0.05) / (darker + 0.05)
    }

    /// `foreground` drawn at `alpha` over `background` (straight sRGB alpha blend, as the renderer composites it).
    private static func blend(_ foreground: UInt32, _ alpha: Double, over background: UInt32) -> UInt32 {
        func channel(_ shift: UInt32) -> UInt32 {
            let top = Double((foreground >> shift) & 0xFF)
            let bottom = Double((background >> shift) & 0xFF)
            return UInt32((top * alpha + bottom * (1 - alpha)).rounded())
        }
        return (channel(16) << 16) | (channel(8) << 8) | channel(0)
    }

    // MARK: - Paints, pairs and thresholds

    /// A color as a screen draws it: a palette token, or a token blended at an opacity over another.
    private struct Paint {
        let name: String
        let value: ColorValue

        init(_ name: String, _ value: ColorValue) {
            self.name = name
            self.value = value
        }

        func opacity(_ alpha: Double, over background: Paint) -> Paint {
            Paint(
                "\(name)@\(Int((alpha * 100).rounded()))% over \(background.name)",
                ColorValue(
                    light: ContrastTests.blend(value.light, alpha, over: background.value.light),
                    dark: ContrastTests.blend(value.dark, alpha, over: background.value.dark),
                    lightHighContrast: ContrastTests.blend(
                        value.lightHighContrast, alpha, over: background.value.lightHighContrast),
                    darkHighContrast: ContrastTests.blend(
                        value.darkHighContrast, alpha, over: background.value.darkHighContrast)))
        }
    }

    private enum Kind {
        /// Body text of any size below WCAG's "large" (24 pt regular, 18.66 pt bold): 4.5:1.
        case text
        /// Icons, dots, check marks and the glyph on a filled circle (WCAG 1.4.11 non-text contrast): 3:1.
        case glyph

        var minimum: Double {
            switch self {
            case .text: 4.5
            case .glyph: 3.0
            }
        }
    }

    private struct Pair {
        let foreground: Paint
        let background: Paint
        let kind: Kind
        /// Screens that force dark mode (Dictating) only ever draw the dark values.
        let darkOnly: Bool
        let usedFor: String

        var id: String { "\(foreground.name) on \(background.name)" }

        func appearances() -> [Appearance] {
            darkOnly ? [.dark, .darkHighContrast] : Appearance.allCases
        }

        func ratio(in appearance: Appearance) -> Double {
            ContrastTests.contrastRatio(
                foreground.value.hex(in: appearance), background.value.hex(in: appearance))
        }
    }

    // Tokens as paints.
    private static let ground = Paint("ground", P.ground)
    private static let surface = Paint("surface", P.surface)
    private static let quietFill = Paint("quietFill", P.quietFill)
    private static let tint = Paint("tint", P.tint)
    private static let ink = Paint("ink", P.ink)
    private static let secondary = Paint("secondary", P.secondary)
    private static let mutedText = Paint("mutedText", P.mutedText)
    private static let accent = Paint("accent", P.accent)
    private static let accentInk = Paint("accentInk", P.accentInk)
    private static let accentInkPressed = Paint("accentInkPressed", P.accentInkPressed)
    private static let accentFill = Paint("accentFill", P.accentFill)
    private static let onAccent = Paint("onAccent", P.onAccent)
    private static let success = Paint("success", P.success)
    private static let successInk = Paint("successInk", P.successInk)
    private static let errorInk = Paint("errorInk", P.errorInk)
    private static let stopRed = Paint("stopRed", P.stopRed)
    private static let recordRed = Paint("recordRed", P.recordRed)
    private static let favorite = Paint("favorite", P.favorite)
    private static let privacyBadgeFill = Paint("privacyBadgeFill", P.privacyBadgeFill)
    private static let privacyBadgeInk = Paint("privacyBadgeInk", P.privacyBadgeInk)
    private static let partialAudioFill = Paint("partialAudioFill", P.partialAudioFill)
    private static let partialAudioInk = Paint("partialAudioInk", P.partialAudioInk)
    private static let night = Paint("night", P.night)
    private static let dictationAccent = Paint("dictationAccent", P.dictationAccent)
    /// iOS's grouped-list row (`secondarySystemGroupedBackground`) behind the Form rows in Settings subscreens, which
    /// hide only the scroll background. Not a token: the system draws it.
    private static let systemRow = Paint(
        "systemRow", ColorValue(light: 0xFFFFFF, dark: 0x1C1C1E, darkHighContrast: 0x242426))

    /// White text at an opacity on the Dictating screen's night background (hard-coded `.white.opacity(…)` there).
    private static func white(_ alpha: Double) -> Paint {
        Paint("white", P.onAccent).opacity(alpha, over: night)
    }

    private static func pairs(
        _ foreground: Paint, on backgrounds: [Paint], _ kind: Kind, darkOnly: Bool = false, _ usedFor: String
    ) -> [Pair] {
        backgrounds.map {
            Pair(foreground: foreground, background: $0, kind: kind, darkOnly: darkOnly, usedFor: usedFor)
        }
    }

    /// Every foreground × background pairing the app draws. Backgrounds are tokens too, so this doubles as the list
    /// of which fills carry text.
    private static let table: [Pair] = {
        var table: [Pair] = []
        // Text (4.5:1).
        table += pairs(
            ink, on: [ground, surface, quietFill, tint, systemRow, privacyBadgeFill.opacity(0.7, over: surface)],
            .text, "titles and body text; the privacy-route chip (TransformComponents)")
        table += pairs(
            secondary, on: [ground, surface, quietFill, tint, systemRow], .text,
            "meta, subtitles, section labels; the Create card; quiet chips")
        table += pairs(accentInk, on: [ground, surface, systemRow], .text, "accent text, links, the app tint")
        table += pairs(
            accentInkPressed, on: [tint], .text, "accent text on tint chips (AppColor.accentTextOnTint, badges)")
        table += pairs(successInk, on: [ground, surface, systemRow], .text, "green status text")
        table += pairs(
            errorInk, on: [ground, surface, quietFill, systemRow], .text,
            "error text; the destructive capsule on quietFill")
        table += pairs(
            privacyBadgeInk, on: [privacyBadgeFill, privacyBadgeFill.opacity(0.7, over: surface), surface], .text,
            "on-device badges; \"Clean text on copy\"")
        table += pairs(partialAudioInk, on: [partialAudioFill], .text, "Partial audio, STUB and Draft badges")
        table += pairs(onAccent, on: [accentFill], .text, "filled button labels (Start, Done, Create, Hide)")
        table += pairs(onAccent, on: [stopRed], .text, "Stop & save; the Delete swipe action")
        for (index, speaker) in P.speakers.enumerated() {
            table += pairs(
                Paint("speaker\(index).ink", speaker.ink), on: [ground, surface, tint], .text,
                "speaker label (tint = the current paragraph)")
        }
        // Dictating (dark by design: fixed night background, forced dark scheme).
        table += pairs(white(0.94), on: [night], .text, "Dictating settled text")
        table += pairs(white(0.9), on: [night], .text, "Dictating paused message")
        table += pairs(white(0.82), on: [night], .text, "Dictating status line")
        table += pairs(white(0.72), on: [night], .text, "Dictating captions and control labels")
        table += pairs(white(0.6), on: [night], .text, "Dictating dimmed text while finishing")
        table += pairs(
            white(P.dictationTentativeOpacity), on: [night], .text, "Dictating tentative tail and \"Listening…\"")
        table += pairs(dictationAccent, on: [night], .text, "Dictating errors, caret, \"Then:\" chip")
        table += pairs(success, on: [night], .text, darkOnly: true, "Dictating \"Copied to your clipboard\"")
        // Glyphs (3:1).
        table += pairs(accent, on: [ground, surface, tint], .glyph, "coral glyphs; the selected tile's check")
        table += pairs(onAccent, on: [accent], .glyph, "white glyph on the Create, Play and Send circles")
        table += pairs(onAccent, on: [recordRed], .glyph, "Edit by voice's listening circle")
        table += pairs(onAccent, on: [success], .glyph, "Create's done check")
        table += pairs(onAccent, on: [night], .glyph, "link cover glyph; Dictating's Stop square")
        table += pairs(ground, on: [ink], .glyph, "Ask's Stop answering glyph")
        table += pairs(accentInk, on: [tint], .glyph, "icon tiles")
        table += pairs(success, on: [ground, surface], .glyph, "switch tint, ready dots, check glyphs")
        table += pairs(favorite, on: [ground, surface], .glyph, "the favorite star")
        table += pairs(mutedText, on: [ground, surface], .glyph, "chevrons, the unfavorited star, placeholders")
        table += pairs(recordRed, on: [ground, surface], .glyph, "the recording dot (Meeting)")
        table += pairs(recordRed, on: [night], .glyph, darkOnly: true, "Dictating's recording dot")
        for (index, speaker) in P.speakers.enumerated() {
            table += pairs(
                Paint("speaker\(index).dot", speaker.dot), on: [ground, surface, tint], .glyph, "speaker dot")
        }
        return table
    }()

    // MARK: - Every pair, every appearance

    func testEveryTextAndGlyphPairMeetsWCAGInEveryAppearance() {
        var failures: [String] = []
        for pair in Self.table {
            for appearance in pair.appearances() {
                let ratio = pair.ratio(in: appearance)
                guard ratio < pair.kind.minimum else { continue }
                failures.append(
                    String(
                        format: "%@ in %@: %.2f:1 < %.1f:1 (%@)", pair.id, appearance.rawValue, ratio,
                        pair.kind.minimum, pair.usedFor))
            }
        }
        XCTAssertTrue(failures.isEmpty, "Contrast below WCAG:\n" + failures.joined(separator: "\n"))
    }

    func testIncreaseContrastNeverLowersContrast() {
        // Only where both colors are ours: the system lightens its own grouped-row color under Increase Contrast.
        for pair in Self.table where pair.background.name != "systemRow" {
            for (ordinary, boosted) in [(Appearance.light, Appearance.lightHighContrast), (.dark, .darkHighContrast)]
            where pair.appearances().contains(ordinary) {
                XCTAssertGreaterThanOrEqual(
                    pair.ratio(in: boosted) + 0.005, pair.ratio(in: ordinary),
                    "\(pair.id): Increase Contrast lowers the ratio in \(ordinary.rawValue)")
            }
        }
    }

    func testEveryPaletteTokenIsMeasuredOrDocumentedAsDecorative() {
        // A token that is neither in a measured pair nor on this list is a color nobody checked.
        let decorative: Set<String> = [
            "border",  // hairlines; the card's text carries the meaning (see testHighContrastBorder…)
            "toggleOffTrack",  // a switch's off track; the system draws the knob and state
            "tintBorder", "tintBorderSelected",  // hairlines around tint cards and selected chips
            "rosette",  // the Meeting brand mark
            "coverNight", "seedStrokeDim", "seedStrokeBright",  // Seed-of-Life cover art
        ]
        var measured = Set<String>()
        for pair in Self.table {
            for paint in [pair.foreground, pair.background] {
                measured.insert(String(paint.name.prefix { $0 != "@" }))
            }
        }
        measured.insert("onAccent")  // measured through its white@N% blends too
        let named = Set(P.named.map(\.name))
        XCTAssertEqual(named.subtracting(measured).subtracting(decorative), [], "tokens nobody measured")
        XCTAssertEqual(decorative.subtracting(named), [], "decorative names that are not tokens")
    }

    // MARK: - The dark palette's character (owner's brief, plan 023 F6)

    func testDarkSurfacesAreWarmNearBlackNotPureBlack() {
        for (name, value) in [
            ("ground", P.ground), ("surface", P.surface), ("quietFill", P.quietFill), ("tint", P.tint),
        ] {
            for hex in [value.dark, value.darkHighContrast] {
                let rgb = Tokens.Color.rgbComponents(fromHex: hex)
                XCTAssertNotEqual(hex, 0x000000, "\(name) is pure black")
                XCTAssertLessThan(Self.luminance(hex), 0.03, "\(name) is not near-black")
                XCTAssertGreaterThan(rgb.red, rgb.blue, "\(name) is not warm (red above blue)")
                XCTAssertGreaterThanOrEqual(rgb.red, rgb.green, "\(name) is not warm (red at least green)")
            }
        }
    }

    func testDarkPillsDoNotGlare() {
        // A light pill on a near-black screen glares (audit F6: "Runs on this iPhone"). In dark mode every filled
        // chip is a deep tinted fill, close to the surface it sits on rather than a bright patch.
        for (name, value) in [
            ("tint", P.tint), ("privacyBadgeFill", P.privacyBadgeFill), ("partialAudioFill", P.partialAudioFill),
            ("quietFill", P.quietFill),
        ] {
            for appearance in [Appearance.dark, .darkHighContrast] {
                let fill = value.hex(in: appearance)
                XCTAssertLessThan(Self.luminance(fill), 0.04, "\(name) glares in \(appearance.rawValue)")
                XCTAssertLessThan(
                    Self.contrastRatio(fill, P.surface.hex(in: appearance)), 1.6,
                    "\(name) stands out from the surface like a light patch in \(appearance.rawValue)")
            }
        }
    }

    func testDarkAccentsAreDesaturatedFromTheCanvas() {
        for (name, value) in [
            ("accent", P.accent), ("success", P.success), ("recordRed", P.recordRed), ("stopRed", P.stopRed),
            ("favorite", P.favorite),
        ] {
            XCTAssertLessThan(
                Self.saturation(value.dark), Self.saturation(value.light), "\(name) is not desaturated in dark mode")
        }
    }

    func testDictationTentativeTextIsTheOwnersFortySixPercent() {
        // Plan 023 F6 (owner, 2026-09-23): 46% white on night, 4.67:1 — up from the canvas's 42% (4.11:1).
        XCTAssertEqual(P.dictationTentativeOpacity, 0.46, accuracy: 0.0001)
    }

    func testDarkByDesignColorsAreTheSameInEveryAppearance() {
        // The Dictating screen and the covers are dark by design; they must not shift with the system scheme.
        for (name, value) in [
            ("night", P.night), ("coverNight", P.coverNight), ("dictationAccent", P.dictationAccent),
            ("seedStrokeDim", P.seedStrokeDim), ("seedStrokeBright", P.seedStrokeBright), ("onAccent", P.onAccent),
        ] {
            let hexes = Set(Appearance.allCases.map { value.hex(in: $0) })
            XCTAssertEqual(hexes.count, 1, "\(name) changes with the appearance")
        }
    }

    // MARK: - Speakers stay distinguishable

    func testSpeakerColorsStayDistinctFromEachOtherInEveryAppearance() {
        // CIE76 color difference (ΔE) of 25 or more between any two speaker inks, and between any two dots: well
        // past "clearly different at a glance" (about 10).
        for appearance in Appearance.allCases {
            for part in ["ink", "dot"] {
                let hexes = P.speakers.map { (part == "ink" ? $0.ink : $0.dot).hex(in: appearance) }
                for i in hexes.indices {
                    for j in hexes.indices where j > i {
                        let difference = Self.deltaE(hexes[i], hexes[j])
                        XCTAssertGreaterThanOrEqual(
                            difference, 25,
                            "speaker \(part)s \(i) and \(j) are too alike in \(appearance.rawValue): ΔE \(difference)")
                    }
                }
            }
        }
    }

    func testSpeakerPaletteWrapsAroundFourColors() {
        XCTAssertEqual(P.speakers.count, 4)
        XCTAssertEqual(Tokens.Color.speakers.count, P.speakers.count)
    }

    // MARK: - Increase Contrast (F5) and icon-only tokens (F4), kept from polish lane u1

    func testHighContrastBorderIsMoreVisibleThanTheOrdinaryHairlineInBothSchemes() {
        // The canvas's hairline is intentionally subtle (1.18:1 against `ground`); Increase Contrast guarantees a
        // real step up in both schemes, not full 3:1 (that would abandon the palette's character).
        for (ordinary, boosted) in [(Appearance.light, Appearance.lightHighContrast), (.dark, .darkHighContrast)] {
            XCTAssertGreaterThan(
                Self.contrastRatio(P.border.hex(in: boosted), P.ground.hex(in: boosted)),
                Self.contrastRatio(P.border.hex(in: ordinary), P.ground.hex(in: ordinary)))
        }
    }

    func testSuccessFailsAsTextSoItMustStayIconOnly() {
        // `success` is documented "icon and dot-fill only" because it fails as text in light mode (3.16:1). Text
        // reads `successInk`.
        XCTAssertLessThan(Self.contrastRatio(P.success.light, P.surface.light), 4.5)
    }

    func testMutedTextBaseFailsAsTextSoItMustStayIconOnly() {
        // `mutedText` is documented "icon/placeholder fill only" (3.19:1); text reads `secondary`.
        XCTAssertLessThan(Self.contrastRatio(P.mutedText.light, P.surface.light), 4.5)
    }

    func testColorValueFallsBackToTheOrdinaryValueWithoutAnIncreaseContrastVariant() {
        let value = ColorValue(light: 0x111111, dark: 0x222222)
        XCTAssertEqual(value.hex(in: .lightHighContrast), 0x111111)
        XCTAssertEqual(value.hex(in: .darkHighContrast), 0x222222)
        XCTAssertEqual(ColorValue.fixed(0x333333).hex(in: .dark), 0x333333)
    }

    // MARK: - Color science helpers

    /// HSL saturation in `[0, 1]`.
    private static func saturation(_ hex: UInt32) -> Double {
        let rgb = Tokens.Color.rgbComponents(fromHex: hex)
        let high = max(rgb.red, rgb.green, rgb.blue)
        let low = min(rgb.red, rgb.green, rgb.blue)
        let lightness = (high + low) / 2
        guard high != low else { return 0 }
        return (high - low) / (1 - abs(2 * lightness - 1))
    }

    /// CIE 1976 color difference between two sRGB colors (D65 white).
    private static func deltaE(_ a: UInt32, _ b: UInt32) -> Double {
        let (l1, a1, b1) = lab(a)
        let (l2, a2, b2) = lab(b)
        return ((l1 - l2) * (l1 - l2) + (a1 - a2) * (a1 - a2) + (b1 - b2) * (b1 - b2)).squareRoot()
    }

    private static func lab(_ hex: UInt32) -> (Double, Double, Double) {
        let rgb = Tokens.Color.rgbComponents(fromHex: hex)
        let (r, g, b) = (linearize(rgb.red), linearize(rgb.green), linearize(rgb.blue))
        let x = (0.4124564 * r + 0.3575761 * g + 0.1804375 * b) / 0.95047
        let y = 0.2126729 * r + 0.7151522 * g + 0.0721750 * b
        let z = (0.0193339 * r + 0.1191920 * g + 0.9503041 * b) / 1.08883
        func f(_ t: Double) -> Double { t > 216.0 / 24389.0 ? cbrt(t) : (24389.0 / 27.0 * t + 16) / 116 }
        let (fx, fy, fz) = (f(x), f(y), f(z))
        return (116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))
    }
}
