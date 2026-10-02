// UX audit F23 / plan 023: the inline resolver `MarkdownDocument` and `PlainTextFlattener` both build on. Pins the
// behavior `MarkdownInline`'s doc comment claims — ambiguous markers stay literal, links keep their address.

@testable import ChirpText
import XCTest

final class MarkdownInlineTests: XCTestCase {
    func testBoldAndItalicAndCodeAreStripped() {
        XCTAssertEqual(
            MarkdownInline.plain("Normal text with *italic* and **bold** and `code`."),
            "Normal text with italic and bold and code.")
    }

    func testUnpairedAsteriskIsMultiplicationNotItalics() {
        XCTAssertEqual(MarkdownInline.plain("2*3"), "2*3")
        XCTAssertEqual(MarkdownInline.plain("Dose is 2*3=6 mg total"), "Dose is 2*3=6 mg total")
    }

    func testUnmatchedBoldMarkerStaysLiteral() {
        XCTAssertEqual(MarkdownInline.plain("This is **bold without close"), "This is **bold without close")
    }

    func testBareBracketWithNoParenIsNotALink() {
        XCTAssertEqual(MarkdownInline.plain("Reference [track] progress"), "Reference [track] progress")
    }

    func testCheckboxBracketsAreNotALink() {
        XCTAssertEqual(MarkdownInline.plain("[ ] Task"), "[ ] Task")
        XCTAssertEqual(MarkdownInline.plain("[x] Task"), "[x] Task")
    }

    func testLinkKeepsBothTheLabelAndTheAddress() {
        // AttributedString(markdown:) alone would render this as just "Google" and drop the URL — a real text
        // loss on Copy (F23's "no text is lost" rule). MarkdownInline rewrites it first so both survive.
        XCTAssertEqual(
            MarkdownInline.plain("See [Google](https://google.com) for more"),
            "See Google (https://google.com) for more")
    }

    func testTextWithNoMarkdownIsUnchanged() {
        let text = "Patient reports mild headache for two days, no fever, no visual changes."
        XCTAssertEqual(MarkdownInline.plain(text), text)
    }

    func testWhitespaceAndLineBreaksArePreserved() {
        XCTAssertEqual(MarkdownInline.plain("Line one\nLine two"), "Line one\nLine two")
    }

    // MARK: - Review fixes 2026-10-01 (plan 024 Task 4): delimiters between letters or digits are the person's

    /// R2-8: Foundation reads GitHub's single-tilde strikethrough, so two tilde ranges on one line paired and Copy
    /// gave "2550 mg q812h" — a dose corruption pasted into an EMR.
    func testTildeRangesBetweenDigitsStayLiteral() {
        XCTAssertEqual(
            MarkdownInline.plain("metoprolol 25~50 mg q8~12h"), "metoprolol 25~50 mg q8~12h")
        XCTAssertEqual(MarkdownInline.plain("dose~2 and dose~3"), "dose~2 and dose~3")
    }

    /// Ruling (plan 024 Task 4): `~` is never strikethrough. Struck text that Copy turns into plain text would read
    /// as live text in the pasted note, so every tilde stays as written, single or double.
    func testTildeNeverStrikesThrough() {
        XCTAssertEqual(MarkdownInline.plain("~~old dose~~ new dose"), "~~old dose~~ new dose")
        XCTAssertEqual(MarkdownInline.plain("~struck~ text"), "~struck~ text")
        XCTAssertEqual(MarkdownInline.plain("H~2~O and ~5 mg"), "H~2~O and ~5 mg")
        XCTAssertFalse(
            MarkdownInline.attributed("~~old dose~~").runs.contains { $0.inlinePresentationIntent != nil },
            "no strikethrough attribute on screen either")
    }

    /// A tilde the source already escaped is one tilde, not a backslash and a tilde.
    func testAlreadyEscapedTildeIsOneTilde() {
        XCTAssertEqual(MarkdownInline.plain("25\\~50 mg q8\\~12h"), "25~50 mg q8~12h")
    }

    /// The "2*3" fix covered one asterisk between digits only; "2**10" twice, or a letter next to the digit, paired
    /// the same way ("210 and 34", "x2 and y3").
    func testAsteriskRunsBetweenLettersOrDigitsStayLiteral() {
        XCTAssertEqual(MarkdownInline.plain("2**10 and 3**4"), "2**10 and 3**4")
        XCTAssertEqual(MarkdownInline.plain("x*2 and y*3"), "x*2 and y*3")
        XCTAssertEqual(MarkdownInline.plain("dose*2 then dose*3"), "dose*2 then dose*3")
        XCTAssertEqual(MarkdownInline.plain("**2**3"), "**2**3")
    }

    /// Real emphasis (a delimiter next to a space or the line's edge) still renders.
    func testRealEmphasisNextToSpacesStillRenders() {
        XCTAssertEqual(
            MarkdownInline.plain("**Plan:** take *twice daily* with `food`"), "Plan: take twice daily with food")
        XCTAssertEqual(MarkdownInline.plain("**2*3** tablets"), "2*3 tablets")
    }

    /// Two runs of the same delimiter with no letter or digit between them can only make emphasis out of punctuation:
    /// a form's blanks paired around "/" and "BP: ___/___ mmHg" copied as "BP: / mmHg".
    func testFormBlanksAroundPunctuationStayLiteral() {
        XCTAssertEqual(MarkdownInline.plain("BP: ___/___ mmHg"), "BP: ___/___ mmHg")
        XCTAssertEqual(MarkdownInline.plain("Date: __/__/____"), "Date: __/__/____")
        XCTAssertEqual(MarkdownInline.plain("a **/** b and x _/_ y"), "a **/** b and x _/_ y")
        XCTAssertEqual(MarkdownInline.plain("__init__ and __/__"), "init and __/__", "real emphasis still renders")
        XCTAssertEqual(MarkdownInline.plain("**Plan:** rest, *(optional)* fluids"), "Plan: rest, (optional) fluids")
        // Blanks inside or after bold: the bold still renders, the blanks stay.
        XCTAssertEqual(MarkdownInline.plain("**BP: ___/___ mmHg**"), "BP: ___/___ mmHg")
        XCTAssertEqual(MarkdownInline.plain("**Plan:** ___/___"), "Plan: ___/___")
        XCTAssertTrue(
            MarkdownInline.attributed("**BP: ___/___ mmHg**").runs.allSatisfy {
                $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true
            }, "the whole line is bold")
    }

    /// Fix round 1: the form-blank rule paired a *closing* run with the next *opening* run whenever only punctuation
    /// separated two emphasized words, so "**" and "_" leaked onto the screen and into Copy. Pairs now follow
    /// CommonMark's own emphasis algorithm: only runs the parser would really pair around letter-free content stay.
    func testEmphasisSeparatedOnlyByPunctuationStillRenders() {
        XCTAssertEqual(
            MarkdownInline.plain("- **Fever**, **chills**, and **cough** for 3 days"),
            "- Fever, chills, and cough for 3 days")
        XCTAssertEqual(
            MarkdownInline.plain("- Pain **8/10** → **3/10** after toradol"), "- Pain 8/10 → 3/10 after toradol")
        XCTAssertEqual(
            MarkdownInline.plain("| **Medication** | **Dose** | **Frequency** |"), "| Medication | Dose | Frequency |")
        XCTAssertEqual(MarkdownInline.plain("**Yes** / **No**"), "Yes / No")
        XCTAssertEqual(MarkdownInline.plain("_Yes_ / _No_"), "Yes / No")
        XCTAssertEqual(MarkdownInline.plain("**a**/**b**, *c*;*d*"), "a/b, c;d")
        // A closer that can also open (an arrow is not punctuation to the parser) still closes its own span.
        XCTAssertEqual(
            MarkdownInline.plain("**8/10**→**3/10** and **Admission**→**Discharge**"),
            "8/10→3/10 and Admission→Discharge")
    }

    /// An escape added inside a code span showed its backslash: CommonMark does not read escapes in code, so "`2*3`"
    /// copied as "2\*3".
    func testInlineCodeIsNeverEscaped() {
        XCTAssertEqual(MarkdownInline.plain("Use `2*3` dosing"), "Use 2*3 dosing")
        XCTAssertEqual(MarkdownInline.plain("Use `25~50` dosing"), "Use 25~50 dosing")
        XCTAssertEqual(MarkdownInline.plain("Code `[a](b)` stays"), "Code [a](b) stays")
    }

    /// CommonMark reads no escapes inside an autolink either, so its address is never escaped (a "~" or "*" in it
    /// would otherwise show a backslash); the angle brackets are autolink syntax and drop, the address stays.
    func testAutolinksAreNeverEscaped() {
        XCTAssertEqual(
            MarkdownInline.plain("See <https://example.com/~user/a_b_c?q=x*y*z> now"),
            "See https://example.com/~user/a_b_c?q=x*y*z now")
        XCTAssertEqual(
            MarkdownInline.plain("Mail <synthetic.user~1@example.com> or <https://example.com/__/__>"),
            "Mail synthetic.user~1@example.com or https://example.com/__/__")
        XCTAssertEqual(
            MarkdownInline.plain("<5 mg> and 25~50 stay text"), "<5 mg> and 25~50 stay text", "not an autolink")
    }

    /// A backtick between two digits is the person's character, not a code span that pairs across the words.
    func testBacktickBetweenDigitsStaysLiteral() {
        XCTAssertEqual(MarkdownInline.plain("5`10 and 6`12"), "5`10 and 6`12")
    }

    /// Known item K3, ruling: entity references are decoded (CommonMark), so the screen and Copy show the same
    /// character. Pinned so the choice is deliberate.
    func testHTMLEntitiesAreDecodedLikeTheScreenShowsThem() {
        XCTAssertEqual(MarkdownInline.plain("Use &lt; for less than."), "Use < for less than.")
        XCTAssertEqual(MarkdownInline.plain("5 &amp; 3 makes 8."), "5 & 3 makes 8.")
        XCTAssertEqual(MarkdownInline.plain("Threshold &#8805; 38.0"), "Threshold ≥ 38.0")
    }

    /// Clinical shapes the inline step must leave alone.
    func testClinicalShapesAreUnchanged() {
        for text in [
            "BP 120/80", "Temp ≥ 38.0", "<5 mg", "q4-6h", ">90% and <5%", "±2", "~5 mg", "5 x 10^9/L", "1/2 tablet",
            "Na_K_ATPase", "Signature: ________", "#1 priority", "+ fever", "- chills",
        ] {
            XCTAssertEqual(MarkdownInline.plain(text), text, text)
        }
    }
}
