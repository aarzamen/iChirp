import Foundation

/// Characters Word stores as a symbol-font code instead of text (`w:sym`, Insert → Symbol): the font name plus a code
/// (`w:char`, usually with the F000 private-use offset). The Symbol font is mapped in full (the Adobe Symbol encoding),
/// so "≥", "≤", "±", "°" and "µ" keep their clinical meaning. Wingdings is mapped only for the check boxes, check marks
/// and square bullet Word's forms use. Any other symbol-font character becomes U+FFFD (the replacement character), so
/// a reader sees that something was there instead of the character silently vanishing.
enum SymbolFontMap {
    /// What stands in for a symbol Parakeet cannot map.
    static let replacement: Character = "\u{FFFD}"

    /// The text for `code` (hex, e.g. "F0B3" or "00B3") in `font`; `replacement` when it cannot be mapped.
    static func character(font: String?, code: String?) -> Character {
        guard let code, let value = UInt32(code.trimmingCharacters(in: .whitespaces), radix: 16) else {
            return replacement
        }
        let fontName = (font ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        let isSymbolArea = (0xF000...0xF0FF).contains(value)
        // Symbol fonts address their 256 glyphs as F000–F0FF (some files omit the offset).
        if let slot = isSymbolArea ? UInt8(value - 0xF000) : (value <= 0xFF ? UInt8(value) : nil) {
            switch fontName {
            case "symbol": return symbol[slot] ?? replacement
            case "wingdings": return wingdings[slot] ?? replacement
            default: if otherSymbolFonts.contains(fontName) || isSymbolArea { return replacement }
            }
        }
        // A text font (or Word's emoji `w16se:symEx`), or a code no symbol font has: the Unicode character itself.
        guard value >= 0x20, !(0xE000...0xF8FF).contains(value), let scalar = Unicode.Scalar(value) else {
            return replacement
        }
        return Character(scalar)
    }

    /// Whether `font` addresses glyphs by position (Symbol, Wingdings and the other symbol fonts), so text set in it
    /// must go through `character(font:code:)`.
    static func isSymbolFont(_ font: String) -> Bool {
        let name = font.trimmingCharacters(in: .whitespaces).lowercased()
        return name == "symbol" || name == "wingdings" || otherSymbolFonts.contains(name)
    }

    /// Fonts whose codes are glyph positions, not Unicode, and that this map does not cover.
    static let otherSymbolFonts: Set<String> = [
        "wingdings 2", "wingdings 3", "webdings", "marlett", "zapf dingbats", "zapfdingbats", "mt extra",
        "ms outlook", "bookshelf symbol 7", "ms reference specialty",
    ]

    /// Wingdings: Word's check boxes (Alt+0168, 0253, 0254), its check and cross marks, and its square bullet.
    static let wingdings: [UInt8: Character] = [
        0xA7: "\u{25AA}", 0xA8: "\u{2610}", 0xFB: "\u{2718}", 0xFC: "\u{2714}", 0xFD: "\u{2612}", 0xFE: "\u{2611}",
    ]

    /// The Adobe Symbol encoding (Unicode's SYMBOL.TXT), with Unicode's bracket and extender pieces for the slots that
    /// table leaves in the private-use area. Slot 0x6D is the micro sign (U+00B5), not the Greek letter mu (U+03BC):
    /// in a clinical document it is the micro prefix of "µg" and "µmol", and the two look the same.
    static let symbol: [UInt8: Character] = {
        // Slots 0x20–0x7E.
        let low: [UInt32] = [
            0x0020, 0x0021, 0x2200, 0x0023, 0x2203, 0x0025, 0x0026, 0x220B,  // 20  ! ∀ # ∃ % & ∋
            0x0028, 0x0029, 0x2217, 0x002B, 0x002C, 0x2212, 0x002E, 0x002F,  // 28 ( ) ∗ + , − . /
            0x0030, 0x0031, 0x0032, 0x0033, 0x0034, 0x0035, 0x0036, 0x0037,  // 30 0–7
            0x0038, 0x0039, 0x003A, 0x003B, 0x003C, 0x003D, 0x003E, 0x003F,  // 38 8 9 : ; < = > ?
            0x2245, 0x0391, 0x0392, 0x03A7, 0x0394, 0x0395, 0x03A6, 0x0393,  // 40 ≅ Α Β Χ Δ Ε Φ Γ
            0x0397, 0x0399, 0x03D1, 0x039A, 0x039B, 0x039C, 0x039D, 0x039F,  // 48 Η Ι ϑ Κ Λ Μ Ν Ο
            0x03A0, 0x0398, 0x03A1, 0x03A3, 0x03A4, 0x03A5, 0x03C2, 0x03A9,  // 50 Π Θ Ρ Σ Τ Υ ς Ω
            0x039E, 0x03A8, 0x0396, 0x005B, 0x2234, 0x005D, 0x22A5, 0x005F,  // 58 Ξ Ψ Ζ [ ∴ ] ⊥ _
            0x203E, 0x03B1, 0x03B2, 0x03C7, 0x03B4, 0x03B5, 0x03C6, 0x03B3,  // 60 ‾ α β χ δ ε φ γ
            0x03B7, 0x03B9, 0x03D5, 0x03BA, 0x03BB, 0x00B5, 0x03BD, 0x03BF,  // 68 η ι ϕ κ λ µ ν ο
            0x03C0, 0x03B8, 0x03C1, 0x03C3, 0x03C4, 0x03C5, 0x03D6, 0x03C9,  // 70 π θ ρ σ τ υ ϖ ω
            0x03BE, 0x03C8, 0x03B6, 0x007B, 0x007C, 0x007D, 0x223C,  // 78 ξ ψ ζ { | } ∼
        ]
        // Slots 0xA0–0xFE; 0 marks 0xF0, which the Symbol font leaves empty.
        let high: [UInt32] = [
            0x20AC, 0x03D2, 0x2032, 0x2264, 0x2044, 0x221E, 0x0192, 0x2663,  // A0 € ϒ ′ ≤ ⁄ ∞ ƒ ♣
            0x2666, 0x2665, 0x2660, 0x2194, 0x2190, 0x2191, 0x2192, 0x2193,  // A8 ♦ ♥ ♠ ↔ ← ↑ → ↓
            0x00B0, 0x00B1, 0x2033, 0x2265, 0x00D7, 0x221D, 0x2202, 0x2022,  // B0 ° ± ″ ≥ × ∝ ∂ •
            0x00F7, 0x2260, 0x2261, 0x2248, 0x2026, 0x23D0, 0x23AF, 0x21B5,  // B8 ÷ ≠ ≡ ≈ … ⏐ ⎯ ↵
            0x2135, 0x2111, 0x211C, 0x2118, 0x2297, 0x2295, 0x2205, 0x2229,  // C0 ℵ ℑ ℜ ℘ ⊗ ⊕ ∅ ∩
            0x222A, 0x2283, 0x2287, 0x2284, 0x2282, 0x2286, 0x2208, 0x2209,  // C8 ∪ ⊃ ⊇ ⊄ ⊂ ⊆ ∈ ∉
            0x2220, 0x2207, 0x00AE, 0x00A9, 0x2122, 0x220F, 0x221A, 0x22C5,  // D0 ∠ ∇ ® © ™ ∏ √ ⋅
            0x00AC, 0x2227, 0x2228, 0x21D4, 0x21D0, 0x21D1, 0x21D2, 0x21D3,  // D8 ¬ ∧ ∨ ⇔ ⇐ ⇑ ⇒ ⇓
            0x25CA, 0x27E8, 0x00AE, 0x00A9, 0x2122, 0x2211, 0x239B, 0x239C,  // E0 ◊ ⟨ ® © ™ ∑ ⎛ ⎜
            0x239D, 0x23A1, 0x23A2, 0x23A3, 0x23A7, 0x23A8, 0x23A9, 0x23AA,  // E8 ⎝ ⎡ ⎢ ⎣ ⎧ ⎨ ⎩ ⎪
            0, 0x27E9, 0x222B, 0x2320, 0x23AE, 0x2321, 0x239E, 0x239F,  // F0 (empty) ⟩ ∫ ⌠ ⎮ ⌡ ⎞ ⎟
            0x23A0, 0x23A4, 0x23A5, 0x23A6, 0x23AB, 0x23AC, 0x23AD,  // F8 ⎠ ⎤ ⎥ ⎦ ⎫ ⎬ ⎭
        ]
        var map: [UInt8: Character] = [:]
        for (start, values) in [(0x20, low), (0xA0, high)] {
            for (offset, value) in values.enumerated() where value != 0 {
                if let scalar = Unicode.Scalar(value) { map[UInt8(start + offset)] = Character(scalar) }
            }
        }
        return map
    }()
}
