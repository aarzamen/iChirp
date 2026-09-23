// UX audit F23 / plan 023: block-level structure. `PlainTextFlattenerTests` covers the plain-text output these
// blocks feed into.

@testable import ChirpText
import XCTest

final class MarkdownBlockParserTests: XCTestCase {
    // MARK: - Headings

    func testHashHeadingsKeepTheirLevel() {
        XCTAssertEqual(
            MarkdownBlockParser.parse("# Title\n\n## Subsection\n\n###### Deep"),
            [
                .heading(level: 1, text: "Title"),
                .heading(level: 2, text: "Subsection"),
                .heading(level: 6, text: "Deep"),
            ])
    }

    func testBoldOnlyLineIsAHeading() {
        // Every built-in template's section-name style (SOAP's "**Subjective**", the summary's "**Key Points**").
        XCTAssertEqual(MarkdownBlockParser.parse("**Subjective**"), [.heading(level: 2, text: "Subjective")])
        XCTAssertEqual(MarkdownBlockParser.parse("__Objective__"), [.heading(level: 2, text: "Objective")])
    }

    func testHashWithNoSpaceIsNotAHeading() {
        XCTAssertEqual(MarkdownBlockParser.parse("#hashtag"), [.paragraph("#hashtag")])
        XCTAssertEqual(MarkdownBlockParser.parse("#1 rule for success"), [.paragraph("#1 rule for success")])
    }

    func testInlineBoldRunsAreNotAHeading() {
        // Two bold spans on one line is a paragraph with emphasis, not a whole-line heading.
        XCTAssertEqual(
            MarkdownBlockParser.parse("**Warning**: check **doses** twice"),
            [.paragraph("**Warning**: check **doses** twice")])
    }

    func testHeadingThatRepeatsTheTitleIsStillAHeadingBlock() {
        // (Unlike ExportDocument.text for PDF/Word, MarkdownDocument never has a title to de-duplicate against —
        // the document screen shows its own title separately, above the rendered body.)
        XCTAssertEqual(MarkdownBlockParser.parse("## Summary"), [.heading(level: 2, text: "Summary")])
    }

    // MARK: - Lists

    func testBulletMarkers() {
        for marker in ["- ", "* ", "+ ", "• "] {
            XCTAssertEqual(
                MarkdownBlockParser.parse("\(marker)Task one\n\(marker)Task two"),
                [.list([
                    MarkdownListItem(level: 0, number: nil, text: "Task one"),
                    MarkdownListItem(level: 0, number: nil, text: "Task two"),
                ])],
                "marker \(marker)")
        }
    }

    func testNumberedListKeepsItsOwnNumbers() {
        XCTAssertEqual(
            MarkdownBlockParser.parse("3. Third\n4. Fourth\n7. Seventh"),
            [.list([
                MarkdownListItem(level: 0, number: 3, text: "Third"),
                MarkdownListItem(level: 0, number: 4, text: "Fourth"),
                MarkdownListItem(level: 0, number: 7, text: "Seventh"),
            ])])
    }

    func testNumberedListAcceptsCloseParenMarker() {
        XCTAssertEqual(
            MarkdownBlockParser.parse("1) First\n2) Second"),
            [.list([
                MarkdownListItem(level: 0, number: 1, text: "First"),
                MarkdownListItem(level: 0, number: 2, text: "Second"),
            ])])
    }

    func testChecklistItemKeepsItsCheckbox() {
        XCTAssertEqual(
            MarkdownBlockParser.parse("- [ ] Call the pharmacy\n- [x] Book follow-up"),
            [.list([
                MarkdownListItem(level: 0, number: nil, text: "[ ] Call the pharmacy"),
                MarkdownListItem(level: 0, number: nil, text: "[x] Book follow-up"),
            ])])
    }

    func testNestedListsIndentByLevel() {
        let markdown = """
            - Top item
              - Nested one level
                - Nested two levels
            - Back to top
            """
        XCTAssertEqual(
            MarkdownBlockParser.parse(markdown),
            [.list([
                MarkdownListItem(level: 0, number: nil, text: "Top item"),
                MarkdownListItem(level: 1, number: nil, text: "Nested one level"),
                MarkdownListItem(level: 2, number: nil, text: "Nested two levels"),
                MarkdownListItem(level: 0, number: nil, text: "Back to top"),
            ])])
    }

    func testMixedBulletAndNumberedLinesFormOneListBlock() {
        XCTAssertEqual(
            MarkdownBlockParser.parse("1. First\n- A note under it"),
            [.list([
                MarkdownListItem(level: 0, number: 1, text: "First"),
                MarkdownListItem(level: 0, number: nil, text: "A note under it"),
            ])])
    }

    // MARK: - Lines that look like lists but are not (plan 023 edge cases)

    func testVitalSignIsNotANumberedListItem() {
        XCTAssertEqual(MarkdownBlockParser.parse("120/80 mmHg"), [.paragraph("120/80 mmHg")])
    }

    func testDecimalDoseIsNotANumberedListItem() {
        XCTAssertEqual(MarkdownBlockParser.parse("3.5 mg dose"), [.paragraph("3.5 mg dose")])
    }

    func testAsteriskMultiplicationIsNotABullet() {
        // "2*3" has no space after the "*", so the bullet-marker check ("* ") never matches.
        XCTAssertEqual(MarkdownBlockParser.parse("2*3 = 6"), [.paragraph("2*3 = 6")])
    }

    // MARK: - Paragraphs

    func testBlankLineSeparatesParagraphs() {
        XCTAssertEqual(
            MarkdownBlockParser.parse("First paragraph.\n\nSecond paragraph."),
            [.paragraph("First paragraph."), .paragraph("Second paragraph.")])
    }

    func testSoftWrappedLinesStayInOneParagraph() {
        XCTAssertEqual(
            MarkdownBlockParser.parse("Line one\nLine two continues it"),
            [.paragraph("Line one\nLine two continues it")])
    }

    func testPlainTextWithNoMarkdownIsOneUnchangedParagraph() {
        let text = "Patient reports mild headache for two days, no fever, no visual changes."
        XCTAssertEqual(MarkdownBlockParser.parse(text), [.paragraph(text)])
    }

    // MARK: - Code

    func testFencedCodeBlockIsShownAsPlainText() {
        let markdown = "Before\n\n```\nlet x = 1\n**not bold**\n```\n\nAfter"
        XCTAssertEqual(
            MarkdownBlockParser.parse(markdown),
            [.paragraph("Before"), .code("let x = 1\n**not bold**"), .paragraph("After")])
    }

    func testFencedCodeBlockWithLanguageTagStillOpensAndCloses() {
        XCTAssertEqual(
            MarkdownBlockParser.parse("```swift\nlet x = 1\n```"),
            [.code("let x = 1")])
    }

    // MARK: - A realistic SOAP note shape

    func testSOAPNoteShape() {
        let markdown = """
            **Subjective**
            Chief complaint: sore throat for three days. No fever reported.

            **Objective**
            - Temp 98.9°F
            - Throat erythematous, no exudate

            **Assessment**
            Viral pharyngitis, likely.

            **Plan**
            - Supportive care, fluids and rest
            - Follow up in 5 days if not improved

            Not documented.
            """
        let blocks = MarkdownBlockParser.parse(markdown)
        XCTAssertEqual(
            blocks,
            [
                .heading(level: 2, text: "Subjective"),
                .paragraph("Chief complaint: sore throat for three days. No fever reported."),
                .heading(level: 2, text: "Objective"),
                .list([
                    MarkdownListItem(level: 0, number: nil, text: "Temp 98.9°F"),
                    MarkdownListItem(level: 0, number: nil, text: "Throat erythematous, no exudate"),
                ]),
                .heading(level: 2, text: "Assessment"),
                .paragraph("Viral pharyngitis, likely."),
                .heading(level: 2, text: "Plan"),
                .list([
                    MarkdownListItem(level: 0, number: nil, text: "Supportive care, fluids and rest"),
                    MarkdownListItem(level: 0, number: nil, text: "Follow up in 5 days if not improved"),
                ]),
                .paragraph("Not documented."),
            ])
    }
}
