// UX audit F23 / plan 023: "no text is lost." A property test, not a fixed example: for many synthetic documents
// built from a seeded, deterministic random generator (headings, paragraphs with inline emphasis, nested and
// numbered lists, code blocks, links, and the plan 023 edge tokens), `PlainTextFlattener.flatten` must keep every
// word of the source, in the same order — it may drop only Markdown's own structural syntax (`#`, `*`, `_`,
// backticks, list markers, fences), never a letter or digit the source actually wrote.

@testable import ChirpText
import Foundation
import XCTest

final class PlainTextFlattenerPropertyTests: XCTestCase {
    /// Deterministic so a failure is reproducible: same seed, same documents, every run.
    private struct SeededGenerator: RandomNumberGenerator {
        private var state: UInt64
        init(seed: UInt64) { state = seed == 0 ? 0x9E3779B97F4A7C15 : seed }
        mutating func next() -> UInt64 {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return state
        }
    }

    func testFlattenedTextKeepsEveryWordOfTheSourceInOrder() {
        var generator = SeededGenerator(seed: 0xC0FFEE)
        for iteration in 0..<200 {
            let markdown = Self.randomDocument(blockCount: Int.random(in: 2...8, using: &generator), using: &generator)
            let flattened = PlainTextFlattener.flatten(markdown)
            XCTAssertEqual(
                Self.words(in: flattened), Self.words(in: markdown),
                "iteration \(iteration) lost or reordered a word.\n--- source ---\n\(markdown)\n--- flattened ---\n\(flattened)"
            )
        }
    }

    /// The same property, pinned against the real representative shapes (`PlainTextFlattenerTests`), not just
    /// random fuzz.
    func testFlattenedTextKeepsEveryWordOfEachBuiltInTemplateShape() {
        let samples = [
            """
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
            """,
            """
            This meeting covered budget planning for Q3 and staffing changes.

            **Key Points**
            - Marketing budget increased by 15% for digital campaigns.
            - Two new hires approved for the engineering team.

            **Decisions & Outcomes**
            - Approved the Q3 marketing budget increase.

            **Open Questions**
            - Who will own the office lease negotiation?
            """,
            """
            **Attendees**
            Speaker 1, Speaker 2

            **Action items**
            - [ ] Speaker 1 to finalize release notes by Thursday
            - [x] Speaker 2 notified the support team
            """,
            """
            Draft agenda for next Tuesday's sync.

            **Agenda**
            1. Release readiness review — Speaker 1
            2. Support ticket backlog — Speaker 2
            3. Q4 planning kickoff
            """,
            "120/80 mmHg\nHeart rate 76 bpm, temp 98.6°F",
            "Total dose 2*3 = 6 tablets, taken with food",
        ]
        for (index, markdown) in samples.enumerated() {
            let flattened = PlainTextFlattener.flatten(markdown)
            XCTAssertEqual(Self.words(in: flattened), Self.words(in: markdown), "sample \(index)")
        }
    }

    // MARK: - Generator

    private static let vocabulary = [
        "patient", "reports", "mild", "headache", "for", "two", "days", "no", "fever", "visual", "changes",
        "chief", "complaint", "sore", "throat", "three", "follow", "up", "in", "five", "supportive", "care",
        "fluids", "rest", "Q3", "Q4", "budget", "marketing", "engineering", "hire", "lease", "renewal",
        "Speaker", "team", "launch", "readiness", "beta", "internal", "testers", "legal", "sign-off",
        "co-worker's", "TCCC_v2", "review", "backlog", "planning", "assessment", "plan", "vitals", "dose",
    ]
    /// The plan 023 edge tokens (a vital sign, a decimal dose, a multiplication) mixed into the fuzz corpus, not
    /// just their own dedicated tests.
    private static let specialTokens = ["120/80", "mmHg", "98.6°F", "3.5", "2*3", "[ ]", "[x]"]

    private static func randomWord(using generator: inout SeededGenerator) -> String {
        (vocabulary + specialTokens).randomElement(using: &generator)!
    }

    private static func randomSentence(wordCount: Int, using generator: inout SeededGenerator) -> String {
        (0..<wordCount).map { _ in randomWord(using: &generator) }.joined(separator: " ")
    }

    private static func randomHeadingLine(using generator: inout SeededGenerator) -> String {
        let text = randomSentence(wordCount: Int.random(in: 1...3, using: &generator), using: &generator)
        return Bool.random(using: &generator) ? "## \(text)" : "**\(text)**"
    }

    private static func randomParagraph(using generator: inout SeededGenerator) -> String {
        let sentence = randomSentence(wordCount: Int.random(in: 3...8, using: &generator), using: &generator)
        guard Bool.random(using: &generator) else { return sentence }
        // Sprinkle inline emphasis around one random word.
        var words = sentence.components(separatedBy: " ")
        let index = Int.random(in: 0..<words.count, using: &generator)
        words[index] = Bool.random(using: &generator) ? "**\(words[index])**" : "*\(words[index])*"
        return words.joined(separator: " ")
    }

    private static func randomList(using generator: inout SeededGenerator) -> [String] {
        let itemCount = Int.random(in: 2...4, using: &generator)
        let ordered = Bool.random(using: &generator)
        var lines: [String] = []
        for index in 0..<itemCount {
            let level = Int.random(in: 0...1, using: &generator)
            let indent = String(repeating: "  ", count: level)
            let text = randomSentence(wordCount: Int.random(in: 2...5, using: &generator), using: &generator)
            let marker = ordered ? "\(index + 1). " : "- "
            lines.append(indent + marker + text)
        }
        return lines
    }

    private static func randomCodeBlock(using generator: inout SeededGenerator) -> [String] {
        ["```", randomSentence(wordCount: 4, using: &generator), "```"]
    }

    private static func randomLinkSentence(using generator: inout SeededGenerator) -> String {
        // Plain vocabulary only: a real generated document never nests "[ ]"/"[x]" inside a link's own label, and
        // a label that itself contains "[" or "]" needs real bracket-nesting support this parser doesn't claim.
        let label = (0..<2).map { _ in vocabulary.randomElement(using: &generator)! }.joined(separator: " ")
        let id = Int.random(in: 1...999, using: &generator)
        return "See [\(label)](https://example.com/\(id)) for details"
    }

    private static func randomDocument(blockCount: Int, using generator: inout SeededGenerator) -> String {
        var lines: [String] = []
        for _ in 0..<blockCount {
            switch Int.random(in: 0..<5, using: &generator) {
            case 0:
                lines.append(randomHeadingLine(using: &generator))
            case 1:
                lines.append(randomParagraph(using: &generator))
            case 2:
                lines.append(contentsOf: randomList(using: &generator))
            case 3:
                lines.append(contentsOf: randomCodeBlock(using: &generator))
            default:
                lines.append(randomLinkSentence(using: &generator))
            }
            lines.append("")  // a blank line between blocks
        }
        return lines.joined(separator: "\n")
    }

    /// Lowercased, split on every non-alphanumeric character (so `**`, `#`, `-`, `.`, `°`, `/` and Markdown's other
    /// structural characters are never mistaken for words on either side of the comparison).
    private static func words(in text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }
}
