import Foundation

/// One of a run's font slots as Word resolves it: an explicit font name, or a theme font. ECMA-376 (17.3.2.26): when a
/// theme attribute (`w:asciiTheme`, `w:hAnsiTheme`, `w:cstheme`) is present, the explicit name beside it is ignored.
/// This reader does not read `theme1.xml`, and theme fonts are text fonts, so a theme slot never maps as symbols.
enum DOCXFontSlot: Equatable, Sendable {
    case named(String)
    case theme

    /// The explicit font name; nil for a theme font.
    var fontName: String? {
        if case .named(let name) = self { return name }
        return nil
    }
}

/// The run properties that decide which font draws a run's characters: the ASCII (`w:ascii`), other (`w:hAnsi`) and
/// complex-script (`w:cs`) font slots, and the right-to-left (`w:rtl`) and complex-script (`w:cs`) switches. nil means
/// "not set at this level": the level below (a style, the document defaults) decides.
struct DOCXRunFonts: Equatable, Sendable {
    var ascii: DOCXFontSlot?
    var hAnsi: DOCXFontSlot?
    var complexScript: DOCXFontSlot?
    var rightToLeft: Bool?
    var complexScriptSwitch: Bool?

    /// `override` laid over these: each slot or switch it sets replaces this one's (Word's cascade).
    func overlaid(with override: DOCXRunFonts) -> DOCXRunFonts {
        DOCXRunFonts(
            ascii: override.ascii ?? ascii, hAnsi: override.hAnsi ?? hAnsi,
            complexScript: override.complexScript ?? complexScript,
            rightToLeft: override.rightToLeft ?? rightToLeft,
            complexScriptSwitch: override.complexScriptSwitch ?? complexScriptSwitch)
    }

    /// Sets the slots one `w:rFonts` element names (a theme attribute wins over the name beside it).
    mutating func setFonts(from attributes: [String: String]) {
        if let slot = Self.slot(name: attributes["w:ascii"], theme: attributes["w:asciiTheme"]) { ascii = slot }
        if let slot = Self.slot(name: attributes["w:hAnsi"], theme: attributes["w:hAnsiTheme"]) { hAnsi = slot }
        if let slot = Self.slot(name: attributes["w:cs"], theme: attributes["w:cstheme"] ?? attributes["w:csTheme"]) {
            complexScript = slot
        }
    }

    /// Sets the `w:rtl` or `w:cs` switch from its element (`w:val` "0", "false" or "off" turns it off).
    mutating func setSwitch(_ element: String, value: String?) {
        let isOn = !["0", "false", "off"].contains(value?.lowercased() ?? "")
        if element == "w:rtl" { rightToLeft = isOn } else { complexScriptSwitch = isOn }
    }

    /// The explicit font Word draws `scalar` in, or nil (a theme font, or none named). A right-to-left or
    /// complex-script run draws every character in its complex-script font; otherwise ASCII uses the ASCII slot and
    /// the rest the other slot, except that a private-use F0xx code (a symbol-font code by definition) may use either.
    func fontName(for scalar: Unicode.Scalar) -> String? {
        if rightToLeft == true || complexScriptSwitch == true { return complexScript?.fontName }
        if scalar.isASCII { return ascii?.fontName }
        if (0xF000...0xF0FF).contains(scalar.value) { return hAnsi?.fontName ?? ascii?.fontName }
        return hAnsi?.fontName
    }

    /// Whether any slot names a symbol font (else no character of the run can map).
    var namesASymbolFont: Bool {
        [ascii, hAnsi, complexScript].contains { $0?.fontName.map(SymbolFontMap.isSymbolFont) == true }
    }

    private static func slot(name: String?, theme: String?) -> DOCXFontSlot? {
        if theme != nil { return .theme }
        return name.map(DOCXFontSlot.named)
    }
}

/// `word/styles.xml`, reduced to what decides a run's font: the document defaults (`w:docDefaults/w:rPrDefault`), the
/// default paragraph style, and each paragraph and character style's run fonts with its `w:basedOn`.
///
/// Not read (documented limits): table styles and list numbering (they style table text and list numbers), linked and
/// latent styles, the theme (`theme1.xml`: theme fonts count as text fonts), and `w:hint` / East Asian slots.
struct DOCXStyles: Sendable {
    struct Style: Sendable {
        var type: String
        var basedOn: String?
        var fonts: DOCXRunFonts
    }

    /// The longest `w:basedOn` chain followed (Word's own limit is similar); a cycle stops earlier.
    static let maximumChainLength = 16

    var defaults = DOCXRunFonts()
    var defaultParagraphStyle: String?
    var styles: [String: Style] = [:]

    /// The styles in `data`, or nil when it is not valid XML (the document then reads as if it had none).
    static func parse(_ data: Data) -> DOCXStyles? {
        let parser = XMLParser(data: data)
        let delegate = StylesParser()
        parser.delegate = delegate
        guard parser.parse() else { return nil }
        return delegate.result
    }

    /// The fonts a run draws in: the document defaults, then its paragraph's style (the default paragraph style when it
    /// names none or an unknown one), then its character style, each with its `w:basedOn` chain.
    func styleFonts(paragraphStyle: String?, characterStyle: String?) -> DOCXRunFonts {
        var fonts = defaults
        let paragraph = paragraphStyle.flatMap { styles[$0]?.type == "paragraph" ? $0 : nil } ?? defaultParagraphStyle
        if let paragraph {
            fonts = fonts.overlaid(with: chainFonts(of: paragraph, type: "paragraph"))
        }
        if let characterStyle {
            fonts = fonts.overlaid(with: chainFonts(of: characterStyle, type: "character"))
        }
        return fonts
    }

    /// `id`'s fonts with its `w:basedOn` chain applied, root first: at most `maximumChainLength` styles of `type`; a
    /// cycle, a missing style or a style of another type ends the chain.
    func chainFonts(of id: String, type: String) -> DOCXRunFonts {
        var chain: [DOCXRunFonts] = []
        var visited: Set<String> = []
        var next: String? = id
        while let current = next, chain.count < Self.maximumChainLength, visited.insert(current).inserted,
            let style = styles[current], style.type == type
        {
            chain.append(style.fonts)
            next = style.basedOn
        }
        return chain.reversed().reduce(DOCXRunFonts()) { $0.overlaid(with: $1) }
    }

    /// Collects the defaults and the styles from `w:styles`.
    private final class StylesParser: NSObject, XMLParserDelegate {
        private(set) var result = DOCXStyles()
        private var path: [String] = []
        private var pending: (id: String, isDefault: Bool, style: Style)?

        func parser(
            _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
            qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]
        ) {
            path.append(elementName)
            switch elementName {
            case "w:style":
                let isDefault = ["1", "true", "on"].contains(attributeDict["w:default"]?.lowercased() ?? "")
                pending = (
                    attributeDict["w:styleId"] ?? "", isDefault,
                    Style(type: attributeDict["w:type"] ?? "paragraph", basedOn: nil, fonts: DOCXRunFonts())
                )
            case "w:basedOn" where path.suffix(2).elementsEqual(["w:style", "w:basedOn"]):
                pending?.style.basedOn = attributeDict["w:val"]
            case "w:rFonts":
                if path.suffix(3).elementsEqual(["w:rPrDefault", "w:rPr", "w:rFonts"]) {
                    result.defaults.setFonts(from: attributeDict)
                } else if path.suffix(3).elementsEqual(["w:style", "w:rPr", "w:rFonts"]) {
                    pending?.style.fonts.setFonts(from: attributeDict)
                }
            case "w:rtl", "w:cs":
                if path.suffix(3).elementsEqual(["w:rPrDefault", "w:rPr", elementName]) {
                    result.defaults.setSwitch(elementName, value: attributeDict["w:val"])
                } else if path.suffix(3).elementsEqual(["w:style", "w:rPr", elementName]) {
                    pending?.style.fonts.setSwitch(elementName, value: attributeDict["w:val"])
                }
            default:
                break
            }
        }

        func parser(
            _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?
        ) {
            if elementName == "w:style" {
                if let pending, !pending.id.isEmpty {
                    result.styles[pending.id] = pending.style
                    if pending.isDefault, pending.style.type == "paragraph", result.defaultParagraphStyle == nil {
                        result.defaultParagraphStyle = pending.id
                    }
                }
                pending = nil
            }
            _ = path.popLast()
        }
    }
}
