import ChirpCore
import XCTest

@testable import ChirpIngest

/// Fix round 2: a run's font is the one Word draws it in, so symbol-font text maps only when Word would show symbols.
/// Theme fonts override explicit names, complex-script runs use the complex-script font, and fonts set by styles
/// (`word/styles.xml`: document defaults, paragraph and character styles with `w:basedOn`) count. Synthetic text only.
final class DOCXRunFontTests: XCTestCase {
    private func text(_ bodyXML: String, styles: String? = nil) throws -> String {
        try DOCXReader.read(SyntheticDOCX.make(bodyXML: bodyXML, stylesXML: styles)).text
    }

    private static func run(_ text: String, properties: String = "") -> String {
        let rPr = properties.isEmpty ? "" : "<w:rPr>\(properties)</w:rPr>"
        return #"<w:r>\#(rPr)<w:t xml:space="preserve">\#(text)</w:t></w:r>"#
    }

    private static func paragraph(_ runs: String..., style: String? = nil) -> String {
        let pPr = style.map { #"<w:pPr><w:pStyle w:val="\#($0)"/></w:pPr>"# } ?? ""
        return "<w:p>\(pPr)" + runs.joined() + "</w:p>"
    }

    private static let symbolFonts = #"<w:rFonts w:ascii="Symbol" w:hAnsi="Symbol"/>"#
    private static let calibriFonts = #"<w:rFonts w:ascii="Calibri" w:hAnsi="Calibri"/>"#

    // MARK: - Item 1: theme fonts and complex-script runs

    /// ECMA-376: when `w:asciiTheme` / `w:hAnsiTheme` is present the explicit name is ignored; Word draws "50 mg".
    func testAThemeFontOverridesTheExplicitSymbolName() throws {
        let themed =
            #"<w:rFonts w:ascii="Symbol" w:hAnsi="Symbol" w:asciiTheme="minorHAnsi" w:hAnsiTheme="minorHAnsi"/>"#
        XCTAssertEqual(try text(Self.paragraph(Self.run("50 mg", properties: themed))), "50 mg")
    }

    /// A right-to-left or complex-script run draws every character in its `w:cs` font.
    func testAComplexScriptRunUsesItsComplexScriptFont() throws {
        let fonts = #"<w:rFonts w:ascii="Symbol" w:hAnsi="Symbol" w:cs="Arial"/>"#
        XCTAssertEqual(try text(Self.paragraph(Self.run("50 mg", properties: fonts + "<w:rtl/>"))), "50 mg")
        XCTAssertEqual(try text(Self.paragraph(Self.run("50 mg", properties: fonts + "<w:cs/>"))), "50 mg")
        let symbolCS = #"<w:rFonts w:ascii="Arial" w:hAnsi="Arial" w:cs="Symbol"/><w:cs/>"#
        XCTAssertEqual(try text(Self.paragraph(Self.run("m", properties: symbolCS))), "µ", "the cs font is Symbol")
        let themedCS = #"<w:rFonts w:ascii="Symbol" w:cs="Symbol" w:cstheme="minorBidi"/><w:rtl/>"#
        XCTAssertEqual(try text(Self.paragraph(Self.run("mg", properties: themedCS))), "mg", "a cs theme wins too")
        let notRTL = Self.symbolFonts + #"<w:rtl w:val="0"/>"#
        XCTAssertEqual(try text(Self.paragraph(Self.run("m", properties: notRTL))), "µ", "w:val=0 turns rtl off")
    }

    /// The positive cases still map.
    func testExplicitSymbolRunsStillMap() throws {
        XCTAssertEqual(
            try text(Self.paragraph(Self.run("50 "), Self.run("m", properties: Self.symbolFonts), Self.run("g"))),
            "50 µg")
        XCTAssertEqual(try text(Self.paragraph(Self.run("\u{F06D}", properties: Self.symbolFonts))), "µ")
    }

    // MARK: - Item 2: fonts set by styles

    private static func characterStyle(_ id: String, basedOn: String? = nil, fonts: String = "") -> String {
        let base = basedOn.map { #"<w:basedOn w:val="\#($0)"/>"# } ?? ""
        let rPr = fonts.isEmpty ? "" : "<w:rPr>\(fonts)</w:rPr>"
        return #"<w:style w:type="character" w:styleId="\#(id)"><w:name w:val="\#(id)"/>\#(base)\#(rPr)</w:style>"#
    }

    private static func paragraphStyle(
        _ id: String, basedOn: String? = nil, fonts: String = "", isDefault: Bool = false
    ) -> String {
        let base = basedOn.map { #"<w:basedOn w:val="\#($0)"/>"# } ?? ""
        let rPr = fonts.isEmpty ? "" : "<w:rPr>\(fonts)</w:rPr>"
        let flag = isDefault ? #" w:default="1""# : ""
        return #"<w:style w:type="paragraph"\#(flag) w:styleId="\#(id)"><w:name w:val="\#(id)"/>"#
            + "\(base)\(rPr)</w:style>"
    }

    private static let themeDefaults = """
        <w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:asciiTheme="minorHAnsi" w:eastAsiaTheme="minorEastAsia" \
        w:hAnsiTheme="minorHAnsi" w:cstheme="minorBidi"/></w:rPr></w:rPrDefault></w:docDefaults>
        """

    private static func styled(_ id: String) -> String {
        #"<w:rStyle w:val="\#(id)"/>"#
    }

    func testACharacterStyleThatSetsSymbolMaps() throws {
        let styles = Self.themeDefaults + Self.characterStyle("SymbolChar", fonts: Self.symbolFonts)
        let body = Self.paragraph(
            Self.run("50 "), Self.run("m", properties: Self.styled("SymbolChar")), Self.run("g"))
        XCTAssertEqual(try text(body, styles: styles), "50 µg")
    }

    func testAParagraphStyleThatSetsSymbolMapsItsRuns() throws {
        let styles = Self.themeDefaults + Self.paragraphStyle("SymbolPara", fonts: Self.symbolFonts)
        XCTAssertEqual(try text(Self.paragraph(Self.run("m"), style: "SymbolPara"), styles: styles), "µ")
        // Direct formatting wins over the paragraph style.
        let direct = Self.run("mg", properties: #"<w:rFonts w:ascii="Calibri" w:hAnsi="Calibri"/>"#)
        XCTAssertEqual(try text(Self.paragraph(direct, style: "SymbolPara"), styles: styles), "mg")
        // The default paragraph style applies to paragraphs without a w:pStyle.
        let defaultSymbol = Self.themeDefaults + Self.paragraphStyle("Normal", fonts: Self.symbolFonts, isDefault: true)
        XCTAssertEqual(try text(Self.paragraph(Self.run("m")), styles: defaultSymbol), "µ")
    }

    func testABasedOnChainIsFollowedAndTheNearestStyleWins() throws {
        let chain =
            Self.themeDefaults + Self.characterStyle("Grand", fonts: Self.symbolFonts)
            + Self.characterStyle("Parent", basedOn: "Grand") + Self.characterStyle("Child", basedOn: "Parent")
        XCTAssertEqual(try text(Self.paragraph(Self.run("m", properties: Self.styled("Child"))), styles: chain), "µ")
        let overridden =
            Self.themeDefaults + Self.characterStyle("Grand", fonts: Self.symbolFonts)
            + Self.characterStyle("Parent", basedOn: "Grand", fonts: Self.calibriFonts)
            + Self.characterStyle("Child", basedOn: "Parent")
        XCTAssertEqual(
            try text(Self.paragraph(Self.run("mg", properties: Self.styled("Child"))), styles: overridden), "mg")
        // A paragraph style's chain, and a character style over it.
        let paragraphs =
            Self.themeDefaults + Self.paragraphStyle("Base", fonts: Self.symbolFonts)
            + Self.paragraphStyle("Heading", basedOn: "Base")
            + Self.characterStyle("Plain", fonts: #"<w:rFonts w:ascii="Calibri" w:hAnsi="Calibri"/>"#)
        XCTAssertEqual(try text(Self.paragraph(Self.run("m"), style: "Heading"), styles: paragraphs), "µ")
        XCTAssertEqual(
            try text(
                Self.paragraph(Self.run("mg", properties: Self.styled("Plain")), style: "Heading"), styles: paragraphs),
            "mg")
    }

    func testAStyleCycleEndsAndKeepsTheStylesOwnFont() throws {
        let cycle =
            Self.themeDefaults + Self.characterStyle("LoopA", basedOn: "LoopB", fonts: Self.symbolFonts)
            + Self.characterStyle("LoopB", basedOn: "LoopA") + Self.characterStyle("Self", basedOn: "Self")
        XCTAssertEqual(try text(Self.paragraph(Self.run("m", properties: Self.styled("LoopA"))), styles: cycle), "µ")
        XCTAssertEqual(try text(Self.paragraph(Self.run("m", properties: Self.styled("LoopB"))), styles: cycle), "µ")
        XCTAssertEqual(try text(Self.paragraph(Self.run("mg", properties: Self.styled("Self"))), styles: cycle), "mg")
    }

    func testStylesThatDoNotSetASymbolFontLeaveTextAlone() throws {
        let calibri =
            Self.themeDefaults
            + Self.characterStyle("Body", fonts: #"<w:rFonts w:ascii="Calibri" w:hAnsi="Calibri"/>"#)
            + Self.characterStyle("Themed", fonts: #"<w:rFonts w:ascii="Symbol" w:asciiTheme="minorHAnsi"/>"#)
        XCTAssertEqual(
            try text(Self.paragraph(Self.run("50 mg", properties: Self.styled("Body"))), styles: calibri), "50 mg")
        XCTAssertEqual(
            try text(Self.paragraph(Self.run("50 mg", properties: Self.styled("Themed"))), styles: calibri), "50 mg")
        XCTAssertEqual(
            try text(Self.paragraph(Self.run("50 mg", properties: Self.styled("Missing"))), styles: calibri), "50 mg",
            "an unknown style id changes nothing")
        // No styles.xml at all: unchanged behavior.
        XCTAssertEqual(try text(Self.paragraph(Self.run("50 mg", properties: Self.styled("SymbolChar")))), "50 mg")
    }

    /// The cascade's order: document defaults, then the paragraph style, then the character style, then the run.
    func testTheCascadeOrder() throws {
        let symbolDefaults =
            #"<w:docDefaults><w:rPrDefault><w:rPr>\#(Self.symbolFonts)</w:rPr></w:rPrDefault></w:docDefaults>"#
        XCTAssertEqual(try text(Self.paragraph(Self.run("m")), styles: symbolDefaults), "µ")
        let calibriParagraph =
            symbolDefaults + Self.paragraphStyle("Body", fonts: #"<w:rFonts w:ascii="Calibri" w:hAnsi="Calibri"/>"#)
        XCTAssertEqual(try text(Self.paragraph(Self.run("mg"), style: "Body"), styles: calibriParagraph), "mg")
        // A style that makes the run right-to-left with a text cs font keeps "mg" even over Symbol slots.
        let rtlStyle =
            Self.themeDefaults
            + Self.characterStyle("RTL", fonts: #"<w:rFonts w:ascii="Symbol" w:hAnsi="Symbol" w:cs="Arial"/><w:rtl/>"#)
        XCTAssertEqual(
            try text(Self.paragraph(Self.run("50 mg", properties: Self.styled("RTL"))), styles: rtlStyle), "50 mg")
    }
}
