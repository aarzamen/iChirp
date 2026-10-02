// UX audit F23 / plan 023 owner decision: "formatted view, plain copy." These pin what Copy actually writes to the
// clipboard for every built-in template's typical output shape, plus the edge cases plan 023 named explicitly.
// `MarkdownBlockParserTests` covers the block structure underneath; `PlainTextFlattenerPropertyTests` covers "no
// text is lost" as a property, not case by case.

@testable import ChirpText
import XCTest

final class PlainTextFlattenerTests: XCTestCase {
    // MARK: - Built-in template shapes

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
        let expected = """
            Subjective

            Chief complaint: sore throat for three days. No fever reported.

            Objective

            - Temp 98.9°F
            - Throat erythematous, no exudate

            Assessment

            Viral pharyngitis, likely.

            Plan

            - Supportive care, fluids and rest
            - Follow up in 5 days if not improved

            Not documented.
            """
        XCTAssertEqual(PlainTextFlattener.flatten(markdown), expected)
    }

    func testSummaryShape() {
        let markdown = """
            This meeting covered budget planning for Q3 and staffing changes.

            **Key Points**
            - Marketing budget increased by 15% for digital campaigns.
            - Two new hires approved for the engineering team.
            - Office lease renewal deferred to next quarter.

            **Decisions & Outcomes**
            - Approved the Q3 marketing budget increase.

            **Open Questions**
            - Who will own the office lease negotiation?
            """
        let expected = """
            This meeting covered budget planning for Q3 and staffing changes.

            Key Points

            - Marketing budget increased by 15% for digital campaigns.
            - Two new hires approved for the engineering team.
            - Office lease renewal deferred to next quarter.

            Decisions & Outcomes

            - Approved the Q3 marketing budget increase.

            Open Questions

            - Who will own the office lease negotiation?
            """
        XCTAssertEqual(PlainTextFlattener.flatten(markdown), expected)
    }

    func testMeetingNotesWithActionItemsShape() {
        let markdown = """
            **Attendees**
            Speaker 1, Speaker 2

            **Summary**
            The team reviewed launch readiness and agreed on next steps.

            **Decisions**
            - Ship the beta to internal testers Friday.

            **Action items**
            - [ ] Speaker 1 to finalize release notes by Thursday
            - [ ] Speaker 2 to notify the support team

            **Open questions**
            - Do we need sign-off from legal before Friday?
            """
        let expected = """
            Attendees

            Speaker 1, Speaker 2

            Summary

            The team reviewed launch readiness and agreed on next steps.

            Decisions

            - Ship the beta to internal testers Friday.

            Action items

            - [ ] Speaker 1 to finalize release notes by Thursday
            - [ ] Speaker 2 to notify the support team

            Open questions

            - Do we need sign-off from legal before Friday?
            """
        XCTAssertEqual(PlainTextFlattener.flatten(markdown), expected)
    }

    func testAgendaShape() {
        let markdown = """
            Draft agenda for next Tuesday's sync.

            **Agenda**
            1. Release readiness review — Speaker 1
            2. Support ticket backlog — Speaker 2
            3. Q4 planning kickoff

            Nothing else is currently open.
            """
        let expected = """
            Draft agenda for next Tuesday's sync.

            Agenda

            1. Release readiness review — Speaker 1
            2. Support ticket backlog — Speaker 2
            3. Q4 planning kickoff

            Nothing else is currently open.
            """
        XCTAssertEqual(PlainTextFlattener.flatten(markdown), expected)
    }

    // MARK: - Edge cases named in plan 023

    func testNestedListsIndentTwoSpacesPerLevel() {
        let markdown = """
            - Top item
              - Nested one level
                - Nested two levels
            - Back to top
            """
        let expected = """
            - Top item
              - Nested one level
                - Nested two levels
            - Back to top
            """
        XCTAssertEqual(PlainTextFlattener.flatten(markdown), expected)
    }

    func testVitalSignLineIsNotTreatedAsAListItem() {
        let text = "120/80 mmHg\nHeart rate 76 bpm"
        XCTAssertEqual(PlainTextFlattener.flatten(text), text)
    }

    func testAsteriskMultiplicationIsNotItalicized() {
        XCTAssertEqual(PlainTextFlattener.flatten("Total dose 2*3 = 6 tablets"), "Total dose 2*3 = 6 tablets")
    }

    func testPlainTextWithNoMarkdownIsUnchanged() {
        let text = "Patient reports mild headache for two days, no fever, no visual changes."
        XCTAssertEqual(PlainTextFlattener.flatten(text), text)
    }

    // MARK: - Other Markdown the model sometimes writes anyway (audit evidence: "## SOAP Note", "### Subjective")

    func testHashHeadingsFlattenTheSameWayAsBoldOnlyHeadings() {
        let markdown = "## SOAP Note\n\n### Subjective\nChief complaint noted."
        let expected = "SOAP Note\n\nSubjective\n\nChief complaint noted."
        XCTAssertEqual(PlainTextFlattener.flatten(markdown), expected)
    }

    func testChecklistItemsKeepTheirCheckbox() {
        let markdown = "- [ ] Call the pharmacy\n- [x] Book follow-up"
        XCTAssertEqual(PlainTextFlattener.flatten(markdown), markdown)
    }

    func testBoldAndItalicMarkersAreStrippedInline() {
        XCTAssertEqual(
            PlainTextFlattener.flatten("This is **bold** and this is *italic* and this is `code`."),
            "This is bold and this is italic and this is code.")
    }

    func testFencedCodeIsShownPlainWithNoInlineParsing() {
        let markdown = "```\nlet x = 1\n**not bold**\n```"
        XCTAssertEqual(PlainTextFlattener.flatten(markdown), "let x = 1\n**not bold**")
    }

    func testBulletMarkerConstantIsHyphenSpace() {
        // Documents the choice plan 023 asked us to pick and record: "-" over "•".
        XCTAssertEqual(PlainTextFlattener.bulletMarker, "- ")
    }

    // MARK: - Review fixes 2026-10-01 (plan 024 Task 4)

    /// Known item K3, ruling: an HTML entity reference is decoded on Copy exactly as the screen shows it (CommonMark
    /// behavior, kept deliberately) — the copied note never says "&#8805;" where the screen said "≥".
    func testHTMLEntitiesDecodeOnCopyAsOnScreen() {
        XCTAssertEqual(
            PlainTextFlattener.flatten("- Threshold &#8805; 38.0\n- 5 &amp; 3 &lt; 9"),
            "- Threshold ≥ 38.0\n- 5 & 3 < 9")
    }

    /// Known item K1: a single "#" plus a space plus prose is the person's "#" ("number of", "fracture"), never a
    /// heading marker to drop.
    func testSingleHashLineKeepsItsHash() {
        XCTAssertEqual(PlainTextFlattener.flatten("# of doses given: 3"), "# of doses given: 3")
        XCTAssertEqual(
            PlainTextFlattener.flatten("**Assessment**\n# L radius\n# HTN, controlled"),
            "Assessment\n\n# L radius\n# HTN, controlled")
    }

    /// Known item K2: "2) second item" copied as "2. second item"; the source delimiter is kept.
    func testCloseParenNumberKeepsItsDelimiter() {
        XCTAssertEqual(PlainTextFlattener.flatten("2) second item"), "2) second item")
        XCTAssertEqual(
            PlainTextFlattener.flatten("1) Start metoprolol\n2) Recheck BP in 2 weeks\n  3. Nested item"),
            "1) Start metoprolol\n2) Recheck BP in 2 weeks\n  3. Nested item")
    }

    /// A "+" finding copies as "+", never as the "-" bullet marker (the opposite finding).
    func testPlusAndMinusFindingsKeepTheirSigns() {
        XCTAssertEqual(
            PlainTextFlattener.flatten("ROS\n+ fever\n+ cough\n- chills"),
            "ROS\n+ fever\n+ cough\n\n- chills")
    }

    /// Review R2-8: a dose range written with tildes copies exactly as written, never as a strikethrough.
    func testTildeDoseRangeCopiesExactly() {
        XCTAssertEqual(
            PlainTextFlattener.flatten("**Plan**\n- metoprolol 25~50 mg q8~12h"),
            "Plan\n\n- metoprolol 25~50 mg q8~12h")
    }
}
