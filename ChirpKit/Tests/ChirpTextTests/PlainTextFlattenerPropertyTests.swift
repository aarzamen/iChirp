// UX audit F23 / plan 023: "no text is lost." A property test, not a fixed example: for many synthetic documents
// built from a seeded, deterministic random generator (headings, paragraphs with inline emphasis, nested and
// numbered lists, code blocks, links, and the plan 023 edge tokens), `PlainTextFlattener.flatten` must keep every
// word of the source, in the same order — it may drop only Markdown's own structural syntax (`#`, `*`, `_`,
// backticks, list markers, fences), never a letter or digit the source actually wrote.
//
// Plan 024 Task 4 (review fixes 2026-10-01): comparing alphanumeric words alone could not see a changed *symbol* —
// "2) second item" copied as "2. second item", "# of doses given: 3" lost its "#", "25~50 mg" lost its tilde. The
// generator now records every content token it writes (each word, number and clinical symbol, and whole clinical
// lines whose first character is the point), and every one must appear in the copied text verbatim and in order.

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

    /// Source lines plus the content tokens they hold, in reading order: what Copy must keep verbatim.
    private struct Generated {
        var lines: [String] = []
        var tokens: [String] = []
        /// Whole lines the copied text must contain exactly: a token check alone cannot see a leaked "**".
        var exactLines: [String] = []

        mutating func append(_ other: Generated) {
            lines += other.lines
            tokens += other.tokens
            exactLines += other.exactLines
        }
    }

    func testFlattenedTextKeepsEveryWordOfTheSourceInOrder() {
        var generator = SeededGenerator(seed: 0xC0FFEE)
        for iteration in 0..<200 {
            let document = Self.randomDocument(blockCount: Int.random(in: 2...8, using: &generator), using: &generator)
            let markdown = document.lines.joined(separator: "\n")
            let flattened = PlainTextFlattener.flatten(markdown)
            XCTAssertEqual(
                Self.words(in: flattened), Self.words(in: markdown),
                "iteration \(iteration) lost or reordered a word.\n--- source ---\n\(markdown)\n--- flattened ---\n\(flattened)"
            )
        }
    }

    /// The symbol-aware property: every token the generator wrote as content (not as Markdown decoration) is in the
    /// copied text exactly as written — no character dropped, swapped or added inside it — and in order.
    func testFlattenedTextKeepsEveryTokenVerbatimInOrder() {
        var generator = SeededGenerator(seed: 0x5EED_0024)
        for iteration in 0..<300 {
            let document = Self.randomDocument(blockCount: Int.random(in: 2...8, using: &generator), using: &generator)
            let markdown = document.lines.joined(separator: "\n")
            let flattened = PlainTextFlattener.flatten(markdown)
            if let missing = Self.firstMissingToken(document.tokens, in: flattened) {
                XCTFail(
                    "iteration \(iteration) changed or lost \(missing.debugDescription).\n--- source ---\n\(markdown)\n--- flattened ---\n\(flattened)"
                )
            }
            let flattenedLines = Set(flattened.components(separatedBy: "\n"))
            for line in document.exactLines where !flattenedLines.contains(line) {
                XCTFail(
                    "iteration \(iteration) did not copy \(line.debugDescription) exactly.\n--- source ---\n\(markdown)\n--- flattened ---\n\(flattened)"
                )
            }
        }
    }

    /// Fix round 1, a differential check of `MarkdownInline`'s copy of CommonMark's emphasis algorithm against
    /// Foundation's parser itself: over random lines of words, digits, punctuation, arrows and `*`/`_` runs, the only
    /// characters that may disappear are `*` and `_`, and Foundation never draws emphasis around text with no letter
    /// or digit (a form's blanks and the person's symbols stay as written).
    func testEmphasisIsNeverDrawnAroundLetterFreeText() {
        let pieces = ["*", "**", "_", "__", "___", "a", "Pain", "8", "10", "/", " ", " ", ",", "→", "(", ")", ".", "-", ":"]
        var generator = SeededGenerator(seed: 0xE3_F1_A5)
        for iteration in 0..<2_000 {
            let line = (0..<Int.random(in: 3...14, using: &generator))
                .map { _ in pieces.randomElement(using: &generator)! }.joined()
            let attributed = MarkdownInline.attributed(line)
            let shown = String(attributed.characters)
            XCTAssertTrue(
                Self.isSubsequence(shown, of: line, droppingOnly: ["*", "_"]),
                "iteration \(iteration): \(line.debugDescription) showed \(shown.debugDescription)")
            for span in Self.emphasisSpans(in: attributed) where !span.contains(where: { $0.isLetter || $0.isNumber }) {
                XCTFail("iteration \(iteration): \(line.debugDescription) emphasized \(span.debugDescription)")
            }
        }
    }

    /// The text of each stretch Foundation draws italic or bold, judged whole: a strong span with italics inside
    /// arrives as several runs, and a run at its edge (like "( ") may hold no letter while the span does.
    private static func emphasisSpans(in attributed: AttributedString) -> [String] {
        var spans: [String] = []
        for intent in [InlinePresentationIntent.emphasized, .stronglyEmphasized] {
            var current: String?
            for run in attributed.runs {
                if run.inlinePresentationIntent?.contains(intent) == true {
                    current = (current ?? "") + String(attributed[run.range].characters)
                } else if let finished = current {
                    spans.append(finished)
                    current = nil
                }
            }
            if let finished = current { spans.append(finished) }
        }
        return spans
    }

    /// True when `shown` is `source` with some of the `droppable` characters removed and nothing else changed.
    private static func isSubsequence(_ shown: String, of source: String, droppingOnly droppable: Set<Character>)
        -> Bool
    {
        var shownIndex = shown.startIndex
        for character in source {
            if shownIndex < shown.endIndex, shown[shownIndex] == character {
                shownIndex = shown.index(after: shownIndex)
            } else if !droppable.contains(character) {
                return false
            }
        }
        return shownIndex == shown.endIndex
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

    /// Clinical lines whose every character is the point: each must come back from Copy exactly as written.
    func testClinicalLinesCopyExactlyAsWritten() {
        for line in Self.clinicalInlineLines {
            XCTAssertEqual(PlainTextFlattener.flatten(line), line, line)
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
    /// The plan 023 edge tokens (a vital sign, a decimal dose, a multiplication) and the plan 024 clinical symbols
    /// (tilde ranges, exponent and letter-times-number asterisks, comparison and plus-minus signs), mixed into the
    /// fuzz corpus, not just their own dedicated tests.
    private static let specialTokens = [
        "120/80", "mmHg", "98.6°F", "3.5", "2*3", "[ ]", "[x]",
        "25~50", "q8~12h", "~5", "2**10", "x*2", "≥", "38.0", "<5", ">90%", "q4-6h", "±2", "BP", "1/2", "10^9/L",
    ]
    /// Whole clinical lines that must copy exactly as written, character for character: known items K1 ("#" plus a
    /// space plus prose) and K2 ("2)"), review R2-8 (tilde ranges), the "+" finding and the plan 024 symbols.
    private static let clinicalInlineLines = [
        "metoprolol 25~50 mg q8~12h", "Temp ≥ 38.0 for 2 days", "BP 120/80", "<5 mg daily", "q4-6h as needed",
        "WBC 5 x 10^9/L", "Dose 2*3 then 2*3 again", "Exponent 2**10 and 3**4", "Titrate x*2 then y*3",
        "#1 priority is the BP", "Signature: ________", "# of doses given: 3", "# L radius", "2) second item",
        "+ fever", "_____", "BP: ___/___ mmHg", "Date: __/__/____",
    ]

    private static func randomWord(using generator: inout SeededGenerator) -> String {
        (vocabulary + specialTokens).randomElement(using: &generator)!
    }

    private static func randomSentence(wordCount: Int, using generator: inout SeededGenerator) -> [String] {
        (0..<wordCount).map { _ in randomWord(using: &generator) }
    }

    private static func randomHeadingLine(using generator: inout SeededGenerator) -> Generated {
        let words = randomSentence(wordCount: Int.random(in: 1...3, using: &generator), using: &generator)
        let text = words.joined(separator: " ")
        return Generated(lines: [Bool.random(using: &generator) ? "## \(text)" : "**\(text)**"], tokens: words)
    }

    private static func randomParagraph(using generator: inout SeededGenerator) -> Generated {
        var words = randomSentence(wordCount: Int.random(in: 3...8, using: &generator), using: &generator)
        let tokens = words
        if Bool.random(using: &generator) {
            // Sprinkle inline emphasis around one random word.
            let index = Int.random(in: 0..<words.count, using: &generator)
            words[index] = Bool.random(using: &generator) ? "**\(words[index])**" : "*\(words[index])*"
        }
        return Generated(lines: [words.joined(separator: " ")], tokens: tokens)
    }

    private static func randomList(using generator: inout SeededGenerator) -> Generated {
        let itemCount = Int.random(in: 2...4, using: &generator)
        let ordered = Bool.random(using: &generator)
        let delimiter = Bool.random(using: &generator) ? "." : ")"
        var generated = Generated()
        for index in 0..<itemCount {
            let level = Int.random(in: 0...1, using: &generator)
            let indent = String(repeating: "  ", count: level)
            let words = randomSentence(wordCount: Int.random(in: 2...5, using: &generator), using: &generator)
            let marker = ordered ? "\(index + 1)\(delimiter) " : "- "
            generated.lines.append(indent + marker + words.joined(separator: " "))
            // A numbered item keeps its own number and delimiter on Copy (known item K2), so the marker is content.
            if ordered { generated.tokens.append("\(index + 1)\(delimiter)") }
            generated.tokens += words
        }
        return generated
    }

    private static func randomCodeBlock(using generator: inout SeededGenerator) -> Generated {
        let words = randomSentence(wordCount: 4, using: &generator)
        return Generated(lines: ["```", words.joined(separator: " "), "```"], tokens: [words.joined(separator: " ")])
    }

    private static func randomLinkSentence(using generator: inout SeededGenerator) -> Generated {
        // Plain vocabulary only: a real generated document never nests "[ ]"/"[x]" inside a link's own label, and
        // a label that itself contains "[" or "]" needs real bracket-nesting support this parser doesn't claim.
        let label = (0..<2).map { _ in vocabulary.randomElement(using: &generator)! }
        let id = Int.random(in: 1...999, using: &generator)
        if Bool.random(using: &generator) {
            // An autolink: its angle brackets are syntax, its address (with "~", "_" and "*") is kept verbatim.
            let address = "https://example.com/~ward_\(id)?q=a*b*c"
            return Generated(lines: ["See <\(address)> for details"], tokens: ["See", address, "for", "details"])
        }
        let address = "https://example.com/\(id)"
        return Generated(
            lines: ["See [\(label.joined(separator: " "))](\(address)) for details"],
            tokens: ["See"] + label + ["(\(address))", "for", "details"])
    }

    private static func randomClinicalLine(using generator: inout SeededGenerator) -> Generated {
        let line = clinicalInlineLines.randomElement(using: &generator)!
        return Generated(lines: [line], tokens: [line])
    }

    /// Fix round 1: two to four emphasized words separated only by punctuation ("**Fever**, **chills** / *cough*"):
    /// every marker drops and nothing else changes, so the copied line is known exactly. An arrow with no spaces
    /// ("**8/10**→**3/10**") makes each middle run able to open and close; it is generated for asterisks only,
    /// because CommonMark never lets an underscore between a letter and a non-punctuation symbol open or close.
    private static func randomPunctuatedEmphasis(using generator: inout SeededGenerator) -> Generated {
        let plainWords = vocabulary.filter { $0.allSatisfy { $0.isLetter || $0 == "-" || $0 == "'" } }
        let underscores = Bool.random(using: &generator)
        let delimiters = underscores ? ["__", "_"] : ["**", "*"]
        let separators = [", ", " / ", "/", " → ", " | ", "; ", ": ", " - "] + (underscores ? [] : ["→"])
        var source = ""
        var expected = ""
        var words: [String] = []
        for index in 0..<Int.random(in: 2...4, using: &generator) {
            if index > 0 {
                let separator = separators.randomElement(using: &generator)!
                source += separator
                expected += separator
            }
            let word = plainWords.randomElement(using: &generator)!
            let delimiter = delimiters.randomElement(using: &generator)!
            source += delimiter + word + delimiter
            expected += word
            words.append(word)
        }
        let line = "Findings " + source + " today"
        let copied = "Findings " + expected + " today"
        return Generated(lines: [line], tokens: ["Findings"] + words + ["today"], exactLines: [copied])
    }

    private static func randomDocument(blockCount: Int, using generator: inout SeededGenerator) -> Generated {
        var document = Generated()
        for _ in 0..<blockCount {
            switch Int.random(in: 0..<7, using: &generator) {
            case 0:
                document.append(randomHeadingLine(using: &generator))
            case 1:
                document.append(randomParagraph(using: &generator))
            case 2:
                document.append(randomList(using: &generator))
            case 3:
                document.append(randomCodeBlock(using: &generator))
            case 4:
                document.append(randomClinicalLine(using: &generator))
            case 5:
                document.append(randomPunctuatedEmphasis(using: &generator))
            default:
                document.append(randomLinkSentence(using: &generator))
            }
            document.lines.append("")  // a blank line between blocks
        }
        return document
    }

    /// Lowercased, split on every non-alphanumeric character (so `**`, `#`, `-`, `.`, `°`, `/` and Markdown's other
    /// structural characters are never mistaken for words on either side of the comparison).
    private static func words(in text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    /// The first token that is not in `text` verbatim after the previous one, or nil when all are, in order.
    private static func firstMissingToken(_ tokens: [String], in text: String) -> String? {
        var searchStart = text.startIndex
        for token in tokens {
            guard let found = text.range(of: token, range: searchStart..<text.endIndex) else { return token }
            searchStart = found.upperBound
        }
        return nil
    }
}
