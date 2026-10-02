import ChirpCore
import XCTest

@testable import ChirpIngest

/// Review R2-5: characters Word stores outside `w:t` (symbol-font characters, non-breaking hyphens) must survive, and a
/// text box Word writes twice (`mc:Choice` and `mc:Fallback`) is read once. Synthetic text only.
final class DOCXReaderTests: XCTestCase {
    private func text(of bodyXML: String) throws -> String {
        try DOCXReader.read(SyntheticDOCX.make(bodyXML: bodyXML)).text
    }

    private static func run(_ text: String) -> String {
        #"<w:r><w:t xml:space="preserve">\#(text)</w:t></w:r>"#
    }

    private static func symbol(_ char: String, font: String = "Symbol") -> String {
        #"<w:r><w:sym w:font="\#(font)" w:char="\#(char)"/></w:r>"#
    }

    private static func paragraph(_ runs: String...) -> String {
        "<w:p>" + runs.joined() + "</w:p>"
    }

    /// Insert → Symbol with the Symbol font: the clinical comparisons, units and signs keep their meaning.
    func testSymbolFontCharactersKeepTheirClinicalMeaning() throws {
        let cases: [(String, String, String, String)] = [
            ("K ", "F0B3", " 5.5 mmol/L", "K ≥ 5.5 mmol/L"),
            ("SpO2 ", "F0A3", " 92 %", "SpO2 ≤ 92 %"),
            ("Temperature 37.8 ", "F0B0", "C", "Temperature 37.8 °C"),
            ("Glucose 6.1 ", "F0B1", " 2", "Glucose 6.1 ± 2"),
            ("Vitamin B12 50 ", "F06D", "g", "Vitamin B12 50 µg"),
            ("Dose 2 ", "F0B4", " daily", "Dose 2 × daily"),
            ("Creatinine ", "F0AD", " since May", "Creatinine ↑ since May"),
            ("Sodium ", "F0AF", " 128", "Sodium ↓ 128"),
            ("Rate ", "F0B9", " rhythm", "Rate ≠ rhythm"),
            ("eGFR ", "F0BB", " 60", "eGFR ≈ 60"),
            ("", "F044", "T 0.4", "ΔT 0.4"),
            ("", "F061", "-blocker", "α-blocker"),
            ("", "F062", "-agonist", "β-agonist"),
            ("Plan ", "F0AE", " review", "Plan → review"),
            ("Weight ", "F02D", "3 kg", "Weight −3 kg"),
        ]
        for (before, char, after, expected) in cases {
            let body = Self.paragraph(Self.run(before), Self.symbol(char), Self.run(after))
            XCTAssertEqual(try text(of: body), expected, "w:char \(char)")
        }
    }

    /// Some files store the symbol's code without the F000 offset; a non-symbol font's code is plain Unicode.
    func testSymbolCodesWithoutTheOffsetAndUnicodeFonts() throws {
        XCTAssertEqual(
            try text(of: Self.paragraph(Self.run("K "), Self.symbol("00B3"), Self.run(" 5.5"))), "K ≥ 5.5")
        XCTAssertEqual(
            try text(of: Self.paragraph(Self.run("pH "), Self.symbol("2264", font: "Calibri"), Self.run(" 7.2"))),
            "pH ≤ 7.2")
        XCTAssertEqual(try text(of: Self.paragraph(Self.symbol("f06d", font: "SYMBOL"), Self.run("g"))), "µg")
    }

    /// Word's check boxes from Wingdings read as boxes; a symbol Parakeet cannot map is a visible replacement
    /// character, never silently dropped.
    func testWingdingsBoxesAndUnknownSymbolsStayVisible() throws {
        let form = Self.paragraph(
            Self.symbol("F0FE", font: "Wingdings"), Self.run(" Diabetic "),
            Self.symbol("F0A8", font: "Wingdings"), Self.run(" Smoker "),
            Self.symbol("F0FD", font: "Wingdings"), Self.run(" Allergy"))
        XCTAssertEqual(try text(of: form), "☑ Diabetic ☐ Smoker ☒ Allergy")
        let unknown = Self.paragraph(Self.run("Mark "), Self.symbol("F021", font: "Webdings"), Self.run(" here"))
        XCTAssertEqual(try text(of: unknown), "Mark \u{FFFD} here")
        let unmapped = Self.paragraph(Self.run("Mark "), Self.symbol("F0F0"), Self.run(" here"))
        XCTAssertEqual(try text(of: unmapped), "Mark \u{FFFD} here", "a Symbol slot with no character")
    }

    func testNonBreakingHyphenIsKept() throws {
        let body = Self.paragraph(Self.run("Take 1"), "<w:r><w:noBreakHyphen/></w:r>", Self.run("2 tablets"))
        XCTAssertEqual(try text(of: body), "Take 1\u{2011}2 tablets")
    }

    /// Word 2010+ writes a text box twice: the drawing (`mc:Choice`) and a VML copy (`mc:Fallback`).
    func testTextBoxTextIsReadOnce() throws {
        let box = """
            <w:p><w:r><mc:AlternateContent>\
            <mc:Choice Requires="wps"><w:drawing><wp:anchor><a:graphic><a:graphicData><wps:wsp><wps:txbx>\
            <w:txbxContent><w:p><w:r><w:t>Synthetic Clinic Letterhead</w:t></w:r></w:p></w:txbxContent>\
            </wps:txbx></wps:wsp></a:graphicData></a:graphic></wp:anchor></w:drawing></mc:Choice>\
            <mc:Fallback><w:pict><v:shape><v:textbox>\
            <w:txbxContent><w:p><w:r><w:t>Synthetic Clinic Letterhead</w:t></w:r></w:p></w:txbxContent>\
            </v:textbox></v:shape></w:pict></mc:Fallback>\
            </mc:AlternateContent></w:r><w:r><w:t>Referral for a synthetic patient.</w:t></w:r></w:p>
            """
        let extracted = try text(of: box + Self.paragraph(Self.run("Second paragraph.")))
        XCTAssertEqual(extracted.components(separatedBy: "Synthetic Clinic Letterhead").count - 1, 1, extracted)
        XCTAssertEqual(
            extracted,
            "Synthetic Clinic Letterhead\n\nReferral for a synthetic patient.\n\nSecond paragraph.")
    }

    /// When the preferred content (`mc:Choice`) holds no text Parakeet can read, the fallback's text is used, so
    /// nothing is lost; Word's emoji symbol (`w16se:symEx`) is read as its character.
    func testFallbackIsReadWhenTheChoiceHasNoReadableText() throws {
        let unknownChoice = """
            <w:p><w:r><w:t xml:space="preserve">Before </w:t></w:r><w:r><mc:AlternateContent>\
            <mc:Choice Requires="w14"><w14:somethingNew w14:val="1"/></mc:Choice>\
            <mc:Fallback><w:t>fallback words</w:t></mc:Fallback>\
            </mc:AlternateContent></w:r><w:r><w:t xml:space="preserve"> after</w:t></w:r></w:p>
            """
        XCTAssertEqual(try text(of: unknownChoice), "Before fallback words after")
        let emoji = """
            <w:p><w:r><w:t xml:space="preserve">Mood </w:t></w:r><w:r><mc:AlternateContent>\
            <mc:Choice Requires="w16se"><w16se:symEx w16se:font="Segoe UI Emoji" w16se:char="1F642"/></mc:Choice>\
            <mc:Fallback><w:t>🙂</w:t></mc:Fallback></mc:AlternateContent></w:r></w:p>
            """
        XCTAssertEqual(try text(of: emoji), "Mood 🙂")
    }

    // MARK: - Tracked changes (fix round 1)

    /// Word moves only a deleted run's text into `w:delText`; its symbols, hyphens, tabs and breaks stay in place
    /// inside `w:del` (and moved-from text stays `w:t` inside `w:moveFrom`). None of it is the document's text.
    func testTrackedDeletionsAndMovesLeakNothing() throws {
        let replacedSymbol = Self.paragraph(
            Self.run("K "),
            #"<w:del w:id="1" w:author="Synthetic"><w:r><w:sym w:font="Symbol" w:char="F0B3"/></w:r></w:del>"#,
            #"<w:ins w:id="2" w:author="Synthetic"><w:r><w:t>≤</w:t></w:r></w:ins>"#, Self.run(" 5.5"))
        XCTAssertEqual(try text(of: replacedSymbol), "K ≤ 5.5")

        let changedRange = Self.paragraph(
            Self.run("Take "),
            #"<w:del w:id="3"><w:r><w:delText>1</w:delText></w:r><w:r><w:noBreakHyphen/></w:r></w:del>"#,
            Self.run("2"), #"<w:ins w:id="4"><w:r><w:noBreakHyphen/><w:t>3</w:t></w:r></w:ins>"#,
            Self.run(" tablets"))
        XCTAssertEqual(try text(of: changedRange), "Take 2\u{2011}3 tablets")

        let deletedLayout = Self.paragraph(
            Self.run("Before"), #"<w:del w:id="5"><w:r><w:tab/><w:br/><w:delText>gone</w:delText></w:r></w:del>"#,
            Self.run(" after"))
        XCTAssertEqual(try text(of: deletedLayout), "Before after")

        let moved =
            Self.paragraph(
                Self.run("First. "), #"<w:moveFrom w:id="6"><w:r><w:t>Moved sentence.</w:t></w:r></w:moveFrom>"#)
            + Self.paragraph(
                Self.run("Second. "), #"<w:moveTo w:id="7"><w:r><w:t>Moved sentence.</w:t></w:r></w:moveTo>"#)
        XCTAssertEqual(try text(of: moved), "First.\n\nSecond. Moved sentence.")

        // A deleted paragraph mark is an empty `w:del` marker in the mark's properties: the text stays.
        let deletedMark = """
            <w:p><w:pPr><w:rPr><w:del w:id="8" w:author="Synthetic"/></w:rPr></w:pPr>\
            <w:r><w:t>Kept text</w:t></w:r></w:p>
            """
        XCTAssertEqual(try text(of: deletedMark), "Kept text")
    }

    // MARK: - Symbol-font runs (fix round 1)

    private static func fontRun(_ text: String, ascii: String, hAnsi: String? = nil) -> String {
        #"<w:r><w:rPr><w:rFonts w:ascii="\#(ascii)" w:hAnsi="\#(hAnsi ?? ascii)"/></w:rPr>"#
            + #"<w:t xml:space="preserve">\#(text)</w:t></w:r>"#
    }

    /// Typing in the Symbol font stores the typed code as run text ("m" for µ), and converted .doc files carry the
    /// F0xx private-use form: both read as the symbol, never as "50 mg".
    func testSymbolFontRunTextReadsAsTheSymbol() throws {
        XCTAssertEqual(
            try text(of: Self.paragraph(Self.run("50 "), Self.fontRun("m", ascii: "Symbol"), Self.run("g"))),
            "50 µg")
        XCTAssertEqual(
            try text(of: Self.paragraph(Self.run("50 "), Self.fontRun("\u{F06D}", ascii: "Symbol"), Self.run("g"))),
            "50 µg")
        XCTAssertEqual(
            try text(of: Self.paragraph(Self.run("K "), Self.fontRun("\u{00B3}", ascii: "Symbol"), Self.run(" 5.5"))),
            "K ≥ 5.5")
        let wingdings = Self.paragraph(Self.fontRun("\u{00FE} \u{00A8} J", ascii: "Wingdings"), Self.run(" Diabetic"))
        XCTAssertEqual(
            try text(of: wingdings), "☑ ☐ \u{FFFD} Diabetic",
            "Wingdings boxes read as boxes, spaces stay spaces, an unmapped glyph shows U+FFFD")
    }

    /// A symbol-font code (F0xx) whose font comes from a style this reader does not read shows as U+FFFD: most fonts
    /// draw nothing for it, so "50 \u{F06D}g" would read as "50 g".
    func testASymbolCodeWithoutAVisibleFontStaysVisible() throws {
        XCTAssertEqual(try text(of: Self.paragraph(Self.run("50 \u{F06D}g"))), "50 \u{FFFD}g")
    }

    /// A text font's run, and a Symbol font set only on the paragraph mark, leave the text alone.
    func testOrdinaryRunsAreUntouched() throws {
        XCTAssertEqual(
            try text(of: Self.paragraph(Self.run("50 "), Self.fontRun("mg", ascii: "Calibri"), Self.run(" daily"))),
            "50 mg daily")
        let markOnly = """
            <w:p><w:pPr><w:rPr><w:rFonts w:ascii="Symbol" w:hAnsi="Symbol"/></w:rPr></w:pPr>\
            <w:r><w:t>Dose 50 mg</w:t></w:r></w:p>
            """
        XCTAssertEqual(try text(of: markOnly), "Dose 50 mg")
        // The run's own font wins over a text box's surrounding run.
        let nested = """
            <w:p><w:r><w:rPr><w:rFonts w:ascii="Symbol"/></w:rPr><mc:AlternateContent><mc:Choice Requires="wps">\
            <w:txbxContent><w:p><w:r><w:t>Box mg</w:t></w:r></w:p></w:txbxContent></mc:Choice></mc:AlternateContent>\
            <w:t>m</w:t></w:r></w:p>
            """
        XCTAssertEqual(try text(of: nested), "Box mg\n\nµ")
        // Letters use the run's ASCII font only: Symbol named for other characters does not turn "mg" into "µg".
        let otherSlotOnly = """
            <w:p><w:r><w:rPr><w:rFonts w:hAnsi="Symbol" w:cs="Symbol"/></w:rPr><w:t>50 mg</w:t></w:r></w:p>
            """
        XCTAssertEqual(try text(of: otherSlotOnly), "50 mg")
        // A tracked formatting change keeps the old font in `w:rPrChange`; the run's current font is what counts.
        let formatChange = """
            <w:p><w:r><w:rPr><w:rFonts w:ascii="Calibri" w:hAnsi="Calibri"/><w:rPrChange w:id="9"><w:rPr>\
            <w:rFonts w:ascii="Symbol" w:hAnsi="Symbol"/></w:rPr></w:rPrChange></w:rPr><w:t>50 mg</w:t></w:r></w:p>
            """
        XCTAssertEqual(try text(of: formatChange), "50 mg")
        // Only `w:r/w:rPr/w:rFonts` names a run's font: a text box paragraph's mark font, met while the anchoring run
        // is open, does not change that run.
        let boxMarkFont = """
            <w:p><w:r><mc:AlternateContent><mc:Choice Requires="wps"><w:txbxContent><w:p><w:pPr><w:rPr>\
            <w:rFonts w:ascii="Symbol" w:hAnsi="Symbol"/></w:rPr></w:pPr><w:r><w:t>Box</w:t></w:r></w:p>\
            </w:txbxContent></mc:Choice></mc:AlternateContent><w:t>50 mg</w:t></w:r></w:p>
            """
        XCTAssertEqual(try text(of: boxMarkFont), "Box\n\n50 mg")
    }

    /// Tab stops in paragraph properties (`w:tabs/w:tab`) are layout, not tab characters.
    func testTabStopDefinitionsAreNotText() throws {
        let tabbed = """
            <w:p><w:pPr><w:tabs><w:tab w:val="left" w:pos="720"/><w:tab w:val="right" w:pos="9000"/></w:tabs>\
            </w:pPr><w:r><w:t>Name</w:t><w:tab/><w:t>Value</w:t></w:r></w:p>
            """
        let body = Self.paragraph(Self.run("First paragraph.")) + tabbed
        XCTAssertEqual(try text(of: body), "First paragraph.\n\nName\tValue")
    }
}
