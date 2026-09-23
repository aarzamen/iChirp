// Polish lane u1-design (ux-audit-2b9ad612 F4/F5/F8): numeric WCAG contrast checks for the text-safe tokens, so a
// future edit to a hex literal in `Tokens.swift` or `AppStyle.swift`'s capsule colors trips a test instead of
// waiting for another manual audit. Uses `Tokens.Color.rgbComponents(fromHex:)` directly — the module README
// already points there for a pure, UIKit-free spot-check — so this runs with a plain `swift test
// --package-path ChirpKit`, no simulator needed.

import XCTest

@testable import ChirpUI

final class ContrastTests: XCTestCase {

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

    // MARK: - Text-safe tokens meet 4.5:1 (light mode; hexes mirrored from Tokens.swift's doc comments)

    func testSuccessInkPassesOnSurfaceAndGround() {
        // successInk = 0x1E7B4A (Tokens.swift); light-mode surfaces are 0xFFFFFF / 0xFAFAF7.
        XCTAssertGreaterThanOrEqual(Self.contrastRatio(0x1E7B4A, 0xFFFFFF), 4.5)
        XCTAssertGreaterThanOrEqual(Self.contrastRatio(0x1E7B4A, 0xFAFAF7), 4.5)
    }

    func testSecondaryPassesOnGround() {
        // secondary's light branch, 0x6B6B6B, on ground's light branch, 0xFAFAF7 (audit: 5.10:1).
        XCTAssertGreaterThanOrEqual(Self.contrastRatio(0x6B6B6B, 0xFAFAF7), 4.5)
    }

    func testAccentInkPassesOnSurface() {
        // accentInk's base, 0xBE4E26, on surface, 0xFFFFFF (audit: 4.88:1).
        XCTAssertGreaterThanOrEqual(Self.contrastRatio(0xBE4E26, 0xFFFFFF), 4.5)
    }

    func testAccentInkPressedPassesOnTint() {
        // F8: the capsule `.tinted` kind's text-on-tint color, 0x8F3A1B, on tint, 0xFFF0EB — the fix for
        // accentInk-on-tint's 4.39:1 failure.
        XCTAssertGreaterThanOrEqual(Self.contrastRatio(0x8F3A1B, 0xFFF0EB), 4.5)
    }

    func testPrivacyBadgeInkPassesOnItsFill() {
        // Regression guard: audit table says 4.69:1.
        XCTAssertGreaterThanOrEqual(Self.contrastRatio(0x1E7B4A, 0xE8F5EC), 4.5)
    }

    func testPartialAudioInkPassesOnItsFill() {
        // Regression guard: audit table says 5.38:1.
        XCTAssertGreaterThanOrEqual(Self.contrastRatio(0x8A5A00, 0xFDF3DF), 4.5)
    }

    // MARK: - Increase Contrast (F5) values step up, never down

    func testHighContrastSecondaryIsAtLeastAsReadableAsSecondary() {
        // secondary's `highContrastLight` value, 0x4F4F4F, must contrast at least as well against ground as the
        // ordinary 0x6B6B6B value it replaces.
        let ordinary = Self.contrastRatio(0x6B6B6B, 0xFAFAF7)
        let boosted = Self.contrastRatio(0x4F4F4F, 0xFAFAF7)
        XCTAssertGreaterThanOrEqual(boosted, ordinary)
        XCTAssertGreaterThanOrEqual(boosted, 4.5)
    }

    func testHighContrastBorderIsMoreVisibleThanTheOrdinaryHairline() {
        // The canvas's hairline border is intentionally subtle (a 1.18:1 whisper against `ground`, nowhere near
        // WCAG 1.4.11's 3:1 UI-component threshold even boosted — turning it fully opaque would abandon "keep the
        // palette's character"). What Increase Contrast should still guarantee is a real step up from the
        // default, not full 3:1.
        let ordinary = Self.contrastRatio(0xE8E8E0, 0xFAFAF7)
        let boosted = Self.contrastRatio(0xBDBDB5, 0xFAFAF7)
        XCTAssertGreaterThan(boosted, ordinary)
    }

    // MARK: - Icon/fill-only tokens are documented, not silently "fixed" (F4)

    func testSuccessFailsAsTextSoItMustStayIconOnly() {
        // `success`, 0x33A854, is documented "icon and dot-fill only" precisely because it fails as text
        // (audit: 3.06:1). If a future change makes this pass, `successInk` may have become redundant — check
        // before deleting it, callers still read `success` for non-text fills.
        XCTAssertLessThan(Self.contrastRatio(0x33A854, 0xFFFFFF), 4.5)
    }

    func testMutedTextBaseFailsAsTextSoItMustStayIconOnly() {
        // `mutedText`'s base, 0x9C9C9C, is documented "icon/placeholder fill only" (audit: 2.75:1); text should
        // read `secondary` instead.
        XCTAssertLessThan(Self.contrastRatio(0x9C9C9C, 0xFFFFFF), 4.5)
    }
}
