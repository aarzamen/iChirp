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
}
