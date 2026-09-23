import XCTest

@testable import ChirpFeatures

final class SpeakableTextTests: XCTestCase {
    func testCitationsAndMarkdownAreNotRead() {
        let markdown = """
            # Summary

            The synthetic speakers agreed to proceed [00:12]. **Owner:** speaker one [1:02:03–1:02:40].

            - Decision: proceed as proposed
            - Follow-up on *Thursday*
            1. First item
            ---
            See [the plan](https://example.com/plan) and `notes`.
            """
        XCTAssertEqual(
            SpeakableText.prepare(markdown),
            """
            Summary.

            The synthetic speakers agreed to proceed. Owner: speaker one.

            Decision: proceed as proposed.
            Follow-up on Thursday.
            1. First item.

            See the plan and notes.
            """)
    }

    func testPlainTextIsUnchanged() {
        let plain = "Blood pressure 120/80. Take 5 mg twice a day, e.g. at 8:30 and 20:30.\n\nNext paragraph."
        XCTAssertEqual(SpeakableText.prepare(plain), plain)
    }
}
