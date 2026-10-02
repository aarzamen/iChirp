import ChirpCore
import ChirpText
import CoreGraphics
import Foundation
import XCTest

#if canImport(PDFKit)
import PDFKit
#endif

@testable import ChirpExport

/// Plan 022 Step 6 (plan 017 items 1–2): a real multi-page PDF (never one truncated page) and a real DOCX. Every
/// transcript here is synthetic.
final class DocumentExportTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(
            "DocumentExportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    /// A synthetic two-hour meeting: 720 turns of about 25 words, two speakers, word timings throughout.
    static func longTranscript() -> Transcription {
        var words: [WordTimestamp] = []
        var ms = 0
        for turn in 0..<720 {
            let speaker = turn.isMultiple(of: 2) ? "S1" : "S2"
            let sentence =
                "Synthetic turn \(turn) says the schedule moves to Thursday and the review of the budget "
                + "continues after the break with two more items to cover before noon."
            let tokens = sentence.split(separator: " ").map(String.init)
            for token in tokens {
                words.append(
                    WordTimestamp(word: token, startMs: ms, endMs: ms + 300, confidence: 0.9, speakerId: speaker))
                ms += 400
            }
            ms += 1_200
        }
        var row = Transcription(
            sourceType: .meeting, fileName: "Synthetic board meeting.caf", durationMs: ms, status: .completed)
        row.wordTimestamps = words
        row.speakers = [SpeakerInfo(id: "S1", label: "Speaker 1"), SpeakerInfo(id: "S2", label: "Speaker 2")]
        row.speakerCount = 2
        row.rawTranscript = words.map(\.word).joined(separator: " ")
        row.derivedTitle = "Synthetic board meeting"
        return row
    }

    // MARK: - The document model

    func testATranscriptBecomesTurnsWithSpeakersAndTimestamps() {
        let document = ExportDocument.transcript(Self.longTranscript(), cleanupMode: .raw)
        XCTAssertEqual(document.title, "Synthetic board meeting")
        XCTAssertTrue(document.metadata.contains { $0.label == "Speakers" && $0.value == "Speaker 1, Speaker 2" })
        XCTAssertTrue(document.metadata.contains { $0.label == "Duration" })
        guard case .turn(let speaker, let timestamp, let text)? = document.blocks.first else {
            return XCTFail("the first block is a turn")
        }
        XCTAssertEqual(speaker, "Speaker 1")
        XCTAssertEqual(timestamp, "00:00")
        XCTAssertTrue(text.hasPrefix("Synthetic turn 0"))
        let turns = document.blocks.filter { if case .turn = $0 { true } else { false } }
        XCTAssertGreaterThanOrEqual(turns.count, 720, "every paragraph kept")
    }

    func testAClinicalItemSaysSoInItsFacts() {
        var row = Transcription(sourceType: .text, fileName: "Text", status: .completed, privacyClass: .clinical)
        row.rawTranscript = "Synthetic line one.\n\nSynthetic line two."
        let document = ExportDocument.transcript(row, cleanupMode: .raw)
        XCTAssertTrue(document.metadata.contains { $0.label == "Privacy" })
        XCTAssertEqual(document.blocks, [.paragraph("Synthetic line one."), .paragraph("Synthetic line two.")])
    }

    /// Plan 022 review M5: the file is marked by the class the privacy rules use (the effective class the caller
    /// passes: a personal transcript with a clinical SOAP note counts as clinical), never lower than the row's own.
    func testTheEffectiveClassMarksTheFileClinical() {
        var row = Transcription(sourceType: .file, fileName: "Visit.m4a", status: .completed)
        row.rawTranscript = "Synthetic visit."
        XCTAssertFalse(ExportDocument.transcript(row, cleanupMode: .raw).metadata.contains { $0.label == "Privacy" })
        let effective = ExportDocument.transcript(row, cleanupMode: .raw, effectivePrivacyClass: .clinical)
        XCTAssertEqual(
            effective.metadata.first { $0.label == "Privacy" }?.value, "Clinical: contains patient information")
        row.privacyClass = .clinical
        let lower = ExportDocument.transcript(row, cleanupMode: .raw, effectivePrivacyClass: .personal)
        XCTAssertTrue(lower.metadata.contains { $0.label == "Privacy" }, "never lower than the row's own class")
    }

    func testGeneratedMarkdownBecomesHeadingsListsAndParagraphs() {
        let body = """
            ## Summary

            ## Decisions
            - **Proceed** with the synthetic plan
            * Keep the `budget`
            1. Call the synthetic clinic
            2) Send the forms

            A closing paragraph
            that wraps.
            """
        let document = ExportDocument.text(title: "Summary", body: body)
        XCTAssertEqual(
            document.blocks,
            [
                .heading("Decisions", level: 2),
                .bullet("Proceed with the synthetic plan"),
                .bullet("Keep the budget"),
                .numbered(marker: "1.", text: "Call the synthetic clinic"),
                .numbered(marker: "2)", text: "Send the forms"),
                .paragraph("A closing paragraph\nthat wraps."),
            ], "the heading that repeats the title is not shown twice")
    }

    // MARK: - One parser for the screen, Copy, PDF and Word (review R1-6, plan 024 Task 4)

    /// R1-6 (a): a SOAP note's section names are bold lines; the old PDF/Word parser merged them into the body, so
    /// the file had no section headings and no keep-with-next.
    func testBoldSectionNamesAreHeadings() {
        let document = ExportDocument.text(
            title: "SOAP note", body: "**Subjective**\nCC: cough\n\n**Plan**\n- Rest and fluids")
        XCTAssertEqual(
            document.blocks,
            [
                .heading("Subjective", level: 2), .paragraph("CC: cough"), .heading("Plan", level: 2),
                .bullet("Rest and fluids"),
            ])
    }

    /// R1-6 (b) and known item K1: "#1 priority" and "# of doses given: 3" are text that keeps its "#".
    func testHashLinesStayTextWithTheirHash() {
        let document = ExportDocument.text(title: "Plan", body: "#1 priority\n\n# of doses given: 3")
        XCTAssertEqual(document.blocks, [.paragraph("#1 priority"), .paragraph("# of doses given: 3")])
    }

    /// R1-6 (c): the old parser deleted every "__" and "**", so a signature blank printed empty and "2**10" printed
    /// "210".
    func testSignatureBlanksAndExponentsAreKept() {
        let document = ExportDocument.text(
            title: "Form", body: "Signature: ________\n\nWBC 2**10 and 3**4\n\nDate: __/__/____")
        XCTAssertEqual(
            document.blocks,
            [
                .paragraph("Signature: ________"), .paragraph("WBC 2**10 and 3**4"),
                .paragraph("Date: __/__/____"),
            ])
    }

    /// R1-6 (d): nested items keep their level; a numbered item keeps its marker as written (known item K2).
    func testNestedListsKeepTheirLevelAndMarkers() {
        let document = ExportDocument.text(
            title: "Plan", body: "- Top item\n  - Nested item\n1) First step\n  2) Nested step\n07. Seventh")
        XCTAssertEqual(
            document.blocks,
            [
                .bullet("Top item"), .bullet("Nested item", level: 1),
                .numbered(marker: "1)", text: "First step"), .numbered(marker: "2)", text: "Nested step", level: 1),
                .numbered(marker: "07.", text: "Seventh"),
            ])
    }

    /// Fenced code, a "+" finding and a tilde dose range print exactly as the screen and Copy show them.
    func testCodePlusFindingsAndTildeRangesPrintAsWritten() {
        let document = ExportDocument.text(
            title: "Note", body: "```\nlet dose = 2*3\n```\n\n+ fever\n- chills\n\nmetoprolol 25~50 mg q8~12h")
        XCTAssertEqual(
            document.blocks,
            [
                .paragraph("let dose = 2*3"), .paragraph("+ fever"), .bullet("chills"),
                .paragraph("metoprolol 25~50 mg q8~12h"),
            ])
    }

    /// The property behind R1-6: for every built-in template's output shape, the PDF/Word text is exactly what Copy
    /// writes — same headings, markers, words, numbers and symbols, in the same order.
    func testPDFAndWordTextMatchesCopyForEveryBuiltInTemplateShape() {
        for (index, body) in Self.templateShapes.enumerated() {
            let document = ExportDocument.text(title: "Synthetic export", body: body)
            XCTAssertEqual(
                Self.copyStyleLines(document), Self.nonBlankLines(PlainTextFlattener.flatten(body)),
                "template shape \(index)")
        }
    }

    /// The rendered files carry the headings and every character: the PDF's text and the Word XML.
    func testThePDFAndWordFileOfASOAPNoteHaveHeadingsAndEveryCharacter() throws {
        let document = ExportDocument.text(title: "SOAP note", body: Self.templateShapes[0])
        let attributed = PDFDocumentRenderer.attributedText(for: document)
        let string = attributed.string as NSString
        let subjective = string.range(of: "Subjective")
        XCTAssertNotEqual(subjective.location, NSNotFound)
        XCTAssertNotNil(
            attributed.attribute(PDFDocumentRenderer.keepWithNext, at: subjective.location, effectiveRange: nil),
            "a section heading never ends a page alone")
        XCTAssertTrue(string.contains("2)\tRecheck BP in 2 weeks"), "the laid-out text keeps the item's own marker")
        #if canImport(PDFKit)
        // PDFKit reads list markers back as their own column, so the marker is checked on its own here.
        let pdfText = try XCTUnwrap(PDFDocument(data: try PDFDocumentRenderer().render(document))?.string)
        for expected in ["Subjective", "# of doses given: 3", "2)", "Recheck BP in 2 weeks", "25~50 mg q8~12h", "≥ 38.0"]
        {
            XCTAssertTrue(pdfText.contains(expected), "PDF text has \(expected)")
        }
        #endif
        let xml = DOCXDocumentWriter.documentXML(document)
        XCTAssertTrue(xml.contains("<w:pStyle w:val=\"Heading2\"/></w:pPr><w:r><w:t xml:space=\"preserve\">Subjective"))
        XCTAssertTrue(xml.contains("# of doses given: 3"))
        XCTAssertTrue(xml.contains(">2)</w:t><w:tab/><w:t xml:space=\"preserve\">Recheck BP in 2 weeks"))
        XCTAssertTrue(xml.contains("<w:ilvl w:val=\"1\"/>"), "a nested bullet is a level-1 Word list item")
        XCTAssertNotNil(try XMLDocument(xmlString: xml), "document.xml is well-formed XML")
    }

    /// Every built-in template's typical output shape (`BuiltInTemplates`), plus the clinical lines plan 024 pins.
    static let templateShapes = [
        """
        **Subjective**
        Chief complaint: cough for 3 days. # of doses given: 3
        # of doses given: 3

        **Objective**
        - Temp ≥ 38.0, BP 120/80
          - Lungs clear
        - SpO2 >90%

        **Assessment**
        # L radius, <5 mg/day

        **Plan**
        1) Start metoprolol 25~50 mg q8~12h
        2) Recheck BP in 2 weeks
        - Not documented.
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

        **Open questions**
        - Do we need sign-off from legal before Friday?
        """,
        """
        Purpose: plan the Q4 launch.

        1. Release readiness review — Speaker 1
        2. Support ticket backlog — Speaker 2
        3. Q4 planning kickoff
        """,
        """
        **Decisions Made**
        - Ship the synthetic beta on Friday (Speaker 1).

        **Action Items**
        - [ ] Speaker 2 books the room by 10/14
        - [ ] Owner not stated: send the forms

        **Needs Follow-Up**
        - Budget sign-off
        """,
        """
        - **The question** — ship now or wait 2 weeks?
        - **The options** — ship with 2*3 testers; wait for 2**10 more.
        - **The recommendation** — wait; see [the plan](https://example.com/plan).
        """,
        """
        **Bottom line:** approve the synthetic budget of $1,000.
        - Costs rose ~5% (±2).
        - Two vendors quoted 25~50 units.
        - Decision needed by 10/15.
        """,
        """
        ## SOAP Note
        ### Subjective
        Patient reports *mild* headache, `no` fever &amp; no rash.
        """,
    ]

    /// The document's blocks written the way Copy writes them, one entry per line, blank lines dropped.
    static func copyStyleLines(_ document: ExportDocument) -> [String] {
        let lines = document.blocks.flatMap { block -> [String] in
            switch block {
            case .heading(let text, _): return [text]
            case .paragraph(let text): return text.components(separatedBy: "\n")
            case .turn(_, _, let text): return [text]
            case .bullet(let text, let level): return [String(repeating: "  ", count: level) + "- " + text]
            case .numbered(let marker, let text, let level):
                return [String(repeating: "  ", count: level) + marker + " " + text]
            }
        }
        return nonBlankLines(lines.joined(separator: "\n"))
    }

    static func nonBlankLines(_ text: String) -> [String] {
        text.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    // MARK: - PDF

    func testALongTranscriptIsAMultiPagePDFWithEveryWord() throws {
        let document = ExportDocument.transcript(Self.longTranscript(), cleanupMode: .raw)
        let data = try PDFDocumentRenderer().render(document)
        let provider = try XCTUnwrap(CGDataProvider(data: data as CFData))
        let pdf = try XCTUnwrap(CGPDFDocument(provider))
        XCTAssertGreaterThan(pdf.numberOfPages, 20, "a two-hour transcript is many pages, never one cut page")
        #if canImport(PDFKit)
        let text = try XCTUnwrap(PDFDocument(data: data)?.string)
        XCTAssertTrue(text.contains("Synthetic turn 0 says"))
        XCTAssertTrue(text.contains("Synthetic turn 719 says"), "the last turn is on the last page")
        XCTAssertTrue(text.contains("Speaker 2"))
        XCTAssertTrue(text.contains("Page \(pdf.numberOfPages) of \(pdf.numberOfPages)"))
        #endif
    }

    func testAShortDocumentIsOnePage() throws {
        let data = try PDFDocumentRenderer().render(ExportDocument.text(title: "Note", body: "One synthetic line."))
        let pdf = try XCTUnwrap(CGDataProvider(data: data as CFData).flatMap(CGPDFDocument.init))
        XCTAssertEqual(pdf.numberOfPages, 1)
    }

    // MARK: - DOCX

    func testTheDOCXUnzipsAndHoldsEveryParagraph() throws {
        let document = ExportDocument.text(
            title: "Synthetic <notes> & plans",
            body: "## Plan\n- First synthetic item\n- Second synthetic item\n\nA paragraph with a tab\there.",
            metadata: [ExportMetadataLine("Date", "Today")])
        let url = try DocumentExporter().write(document, as: .docx, to: folder)
        XCTAssertEqual(url.pathExtension, "docx")

        XCTAssertEqual(try unzip(["-tq", url.path]).status, 0, "the archive and its CRCs are valid")
        let listing = try unzip(["-Z1", url.path]).output
        for part in [
            "[Content_Types].xml", "_rels/.rels", "word/document.xml", "word/styles.xml", "word/numbering.xml",
            "word/_rels/document.xml.rels", "docProps/core.xml",
        ] {
            XCTAssertTrue(listing.contains(part), "missing \(part)")
        }
        let xml = try unzip(["-p", url.path, "word/document.xml"]).output
        XCTAssertTrue(xml.contains("Synthetic &lt;notes&gt; &amp; plans"), "text is escaped")
        XCTAssertTrue(xml.contains("<w:pStyle w:val=\"Heading2\"/>"))
        XCTAssertTrue(xml.contains("First synthetic item"))
        XCTAssertTrue(xml.contains("Second synthetic item"))
        XCTAssertTrue(xml.contains("<w:numId w:val=\"1\"/>"), "bullets are real Word lists")
        XCTAssertTrue(xml.contains("<w:tab/>"))
        XCTAssertNotNil(try XMLDocument(xmlString: xml), "document.xml is well-formed XML")
        let core = try unzip(["-p", url.path, "docProps/core.xml"]).output
        XCTAssertTrue(core.contains("<dc:title>Synthetic &lt;notes&gt; &amp; plans</dc:title>"))
    }

    func testALongTranscriptDOCXKeepsEveryTurn() throws {
        let document = ExportDocument.transcript(Self.longTranscript(), cleanupMode: .raw)
        let data = try DOCXDocumentWriter().render(document)
        let url = folder.appendingPathComponent("long.docx")
        try data.write(to: url)
        let xml = try unzip(["-p", url.path, "word/document.xml"]).output
        XCTAssertTrue(xml.contains("Synthetic turn 0 says"))
        XCTAssertTrue(xml.contains("Synthetic turn 719 says"))
        XCTAssertTrue(xml.contains(">Speaker 2<"))
    }

    /// `CHIRP_EXPORT_SAMPLES=<folder> swift test --filter DocumentExportTests` writes a synthetic transcript and a
    /// synthetic generated document as PDF and Word there, to open and look at.
    func testWritesSamplesWhenAsked() throws {
        guard let path = ProcessInfo.processInfo.environment["CHIRP_EXPORT_SAMPLES"] else {
            throw XCTSkip("Set CHIRP_EXPORT_SAMPLES to a folder to write sample exports.")
        }
        let folder = URL(fileURLWithPath: path, isDirectory: true)
        let transcript = ExportDocument.transcript(Self.longTranscript(), cleanupMode: .raw)
        let soapNote = ExportDocument.text(
            title: "SOAP note", body: Self.templateShapes[0],
            metadata: [ExportMetadataLine("Privacy", "Clinical: a draft for review; contains patient information")])
        let summary = ExportDocument.text(
            title: "Summary",
            body: """
                ## Summary
                The synthetic meeting moved the review to Thursday at nine.

                ## Decisions
                - Proceed with the synthetic plan
                - Keep the synthetic budget as it is

                ## Action items
                1. Speaker 1 sends the forms by Friday
                2. Speaker 2 books the room
                """,
            metadata: [
                ExportMetadataLine("From", "Synthetic board meeting"), ExportMetadataLine("Ran", "On this iPhone"),
            ])
        for format in DocumentExportFormat.allCases {
            _ = try DocumentExporter().write(transcript, as: format, to: folder)
            _ = try DocumentExporter().write(summary, as: format, to: folder)
            _ = try DocumentExporter().write(soapNote, as: format, to: folder)
        }
    }

    func testXMLEscapingDropsWhatXMLCannotHold() {
        XCTAssertEqual(DOCXDocumentWriter.escape("a<b>&\"c'\u{0001}d"), "a&lt;b&gt;&amp;&quot;c&apos;d")
    }

    func testTheCRCMatchesTheStandard() {
        XCTAssertEqual(CRC32.checksum(Data("123456789".utf8)), 0xCBF4_3926)
    }

    func testFileNamesComeFromTheTitle() throws {
        let url = try DocumentExporter().write(ExportDocument.text(title: "Plan: Q3/Q4", body: "x"), as: .pdf, to: folder)
        XCTAssertEqual(url.lastPathComponent, "Plan  Q3 Q4.pdf")
        let untitled = try DocumentExporter().write(ExportDocument.text(title: "  ", body: "x"), as: .docx, to: folder)
        XCTAssertEqual(untitled.lastPathComponent, "document.docx")
    }

    // MARK: - Helpers

    private func unzip(_ arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
