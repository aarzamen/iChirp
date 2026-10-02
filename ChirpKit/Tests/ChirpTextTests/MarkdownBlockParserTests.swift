// UX audit F23 / plan 023: block-level structure. `PlainTextFlattenerTests` covers the plain-text output these
// blocks feed into.

@testable import ChirpText
import XCTest

final class MarkdownBlockParserTests: XCTestCase {
    // MARK: - Headings

    func testHashHeadingsKeepTheirLevel() {
        XCTAssertEqual(
            MarkdownBlockParser.parse("## Subsection\n\n### Part\n\n###### Deep"),
            [
                .heading(level: 2, text: "Subsection"),
                .heading(level: 3, text: "Part"),
                .heading(level: 6, text: "Deep"),
            ])
    }

    /// Known item K1, ruling (plan 024 Task 4): a single "#" is never a heading. In clinical shorthand "#" means
    /// "number of" ("# of doses given: 3"), "fracture" ("# L radius") or a problem-list entry ("# HTN"); reading it
    /// as a heading dropped the "#" on screen, on Copy and in the PDF/Word exports. Two or more hashes still make a
    /// heading, and every built-in template names its sections with a bold line, which is unaffected.
    func testSingleHashLineIsTextThatKeepsItsHash() {
        XCTAssertEqual(
            MarkdownBlockParser.parse("# of doses given: 3"), [.paragraph("# of doses given: 3")])
        XCTAssertEqual(MarkdownBlockParser.parse("# L radius"), [.paragraph("# L radius")])
        XCTAssertEqual(
            MarkdownBlockParser.parse("# SOAP Note\n**Subjective**"),
            [.paragraph("# SOAP Note"), .heading(level: 2, text: "Subjective")],
            "a model's single-# title line shows its # as written (the ruling's cosmetic cost)")
    }

    /// A line of only underscores or asterisks (a signature blank, a divider) is not a bold-only heading: "_____"
    /// used to become a heading whose text was "_", dropping four characters.
    func testDelimiterOnlyLineIsNotAHeading() {
        XCTAssertEqual(MarkdownBlockParser.parse("_____"), [.paragraph("_____")])
        XCTAssertEqual(MarkdownBlockParser.parse("*****"), [.paragraph("*****")])
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
        for marker in ["- ", "* ", "• "] {
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

    /// Known item K2: the item keeps the delimiter it was written with, so "2)" is never shown or copied as "2.".
    func testNumberedListAcceptsCloseParenMarkerAndKeepsIt() {
        XCTAssertEqual(
            MarkdownBlockParser.parse("1) First\n2) Second"),
            [.list([
                MarkdownListItem(level: 0, number: 1, text: "First", marker: "1)"),
                MarkdownListItem(level: 0, number: 2, text: "Second", marker: "2)"),
            ])])
    }

    func testNumberedMarkerIsKeptExactlyAsWritten() {
        XCTAssertEqual(
            MarkdownBlockParser.parse("07. Seventh"),
            [.list([MarkdownListItem(level: 0, number: 7, text: "Seventh", marker: "07.")])])
        XCTAssertEqual(MarkdownListItem(level: 0, number: 3, text: "Third").marker, "3.", "the default delimiter")
        XCTAssertNil(MarkdownListItem(level: 0, number: nil, text: "Bullet").marker)
    }

    /// Ruling (plan 024 Task 4): "+" is not a bullet marker. In clinical writing "+" means present or positive and
    /// "-" absent or negative; as a bullet, "+ fever" was drawn "•" and copied "- fever", the opposite finding.
    func testPlusLineIsTextNotABullet() {
        XCTAssertEqual(MarkdownBlockParser.parse("+ fever\n+ cough"), [.paragraph("+ fever\n+ cough")])
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
