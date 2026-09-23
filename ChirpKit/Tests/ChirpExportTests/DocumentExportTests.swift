import ChirpCore
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
            # Summary

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
                .numbered(1, "Call the synthetic clinic"),
                .numbered(2, "Send the forms"),
                .paragraph("A closing paragraph\nthat wraps."),
            ], "the heading that repeats the title is not shown twice")
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
        let summary = ExportDocument.text(
            title: "Summary",
            body: """
                # Summary
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
        }
    }

    func testXMLEscapingDropsWhatXMLCannotHold() {
        XCTAssertEqual(DOCXDocumentWriter.escape("a<b>&\"c'\u{0001}d"), "a&lt;b&gt;&amp;&quot;c&apos;d")
    }

    func testTheCRCMatchesTheStandard() {
        XCTAssertEqual(CRC32.checksum(Data("123456789".utf8)), 0xCBF4_3926)
    }

    func testFileNamesComeFromTheTitle() {
        XCTAssertEqual(DocumentExporter.fileStem("Plan: Q3/Q4"), "Plan  Q3 Q4")
        XCTAssertEqual(DocumentExporter.fileStem("  "), "document")
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
