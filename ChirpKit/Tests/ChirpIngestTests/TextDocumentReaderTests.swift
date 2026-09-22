import ChirpCore
import XCTest

@testable import ChirpIngest

/// TXT, Markdown, RTF, HTML and DOCX fixtures generated at test time (synthetic text only); malformed files fail with
/// a clear error.
final class TextDocumentReaderTests: XCTestCase {
    private var directory: URL!
    private let extractor = DocumentTextExtractor(recognizer: FakeRecognizer(text: ""))

    override func setUpWithError() throws {
        directory = try makeTemporaryDirectory()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func extract(_ data: Data, name: String) async throws -> ExtractedDocument {
        let url = directory.appendingPathComponent(name)
        try data.write(to: url)
        let format = try XCTUnwrap(DocumentFormat(url: url))
        return try await extractor.extract(from: url, format: format) { _, _ in }
    }

    private func assertFails(
        _ data: Data, name: String, with expected: DocumentExtractionError, file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await extract(data, name: name)
            XCTFail("expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? DocumentExtractionError, expected, file: file, line: line)
            XCTAssertFalse(
                (error as? DocumentExtractionError)?.errorDescription?.isEmpty ?? true, file: file, line: line)
        }
    }

    // MARK: - Plain text and Markdown

    func testPlainTextUTF8AndUTF16AndLatin1() async throws {
        let text = "Synthetic memo.\r\n\r\n\r\nSecond paragraph — café.  "
        let utf8 = try await extract(Data(text.utf8), name: "memo.txt")
        XCTAssertEqual(utf8.text, "Synthetic memo.\n\nSecond paragraph — café.")
        XCTAssertNil(utf8.title)
        XCTAssertNil(utf8.pages)

        var utf16 = Data([0xFF, 0xFE])
        utf16.append(text.data(using: .utf16LittleEndian)!)
        let decoded16 = try await extract(utf16, name: "memo16.txt")
        XCTAssertEqual(decoded16.text, utf8.text)

        let latin1 = try await extract("caf\u{E9} notes".data(using: .windowsCP1252)!, name: "latin.txt")
        XCTAssertEqual(latin1.text, "café notes")
    }

    func testMarkdownKeepsItsTextAndTakesTheFirstHeadingAsTitle() async throws {
        let markdown = """
            # Synthetic Meeting Agenda

            - Item one
            - Item two

            ## Details
            Nothing real here.
            """
        let document = try await extract(Data(markdown.utf8), name: "agenda.md")
        XCTAssertEqual(document.title, "Synthetic Meeting Agenda")
        XCTAssertTrue(document.text.hasPrefix("# Synthetic Meeting Agenda"))
        XCTAssertTrue(document.text.contains("- Item two"))
        XCTAssertEqual(PlainTextReader.markdownTitle(in: "Setext Title\n=====\n\nbody"), "Setext Title")
    }

    func testBinaryAndEmptyTextFilesFail() async {
        await assertFails(
            Data([0x00, 0x01, 0x02, 0x41]), name: "binary.txt",
            with: .malformed(.plainText, "it contains binary data, not text."))
        await assertFails(Data(" \n\n ".utf8), name: "empty.md", with: .noText(.markdown))
    }

    // MARK: - HTML

    func testHTMLKeepsBlocksAndDropsScriptsStylesAndTags() async throws {
        let html = """
            <!doctype html><html><head><title>Synthetic &amp; Simple Page</title>
            <style>p { color: red; }</style><script>var secret = "never shown";</script></head>
            <body><h1>Heading</h1><p>First&nbsp;paragraph with <b>bold</b> and a<br>line break.</p>
            <!-- a comment -->
            <ul><li>One</li><li>Two &#8211; &#x2019;quoted&#x2019;</li></ul>
            <table><tr><td>A</td><td>B</td></tr></table></body></html>
            """
        let document = try await extract(Data(html.utf8), name: "page.html")
        XCTAssertEqual(document.title, "Synthetic & Simple Page")
        XCTAssertFalse(document.text.contains("never shown"))
        XCTAssertFalse(document.text.contains("color"))
        XCTAssertFalse(document.text.contains("<"))
        XCTAssertFalse(document.text.contains("comment"))
        XCTAssertTrue(document.text.hasPrefix("Heading\n\nFirst paragraph with bold and a\nline break."), document.text)
        XCTAssertTrue(document.text.contains("• One"))
        XCTAssertTrue(document.text.contains("• Two – ’quoted’"))
        XCTAssertTrue(document.text.contains("A"))
    }

    func testHTMLWithoutTextFails() async {
        await assertFails(Data("<html><body><img src=x></body></html>".utf8), name: "empty.htm", with: .noText(.html))
    }

    // MARK: - RTF

    func testRTFThroughAttributedString() async throws {
        let rtf =
            #"{\rtf1\ansi\deff0{\fonttbl{\f0 Helvetica;}}{\info{\title Synthetic RTF Title}}\f0 Hello \b bold\b0  world.\par Second line.}"#
        let document = try await extract(Data(rtf.utf8), name: "note.rtf")
        XCTAssertTrue(document.text.contains("Hello bold world."), document.text)
        XCTAssertTrue(document.text.contains("Second line."))
        XCTAssertEqual(document.title, "Synthetic RTF Title")
    }

    func testNotRTFFails() async {
        await assertFails(
            Data("plain words".utf8), name: "fake.rtf", with: .malformed(.rtf, "it is not an RTF file."))
    }

    // MARK: - DOCX

    func testDOCXParagraphsRunsTabsBreaksAndTitle() async throws {
        for deflate in [true, false] {
            let data = SyntheticDOCX.make(
                paragraphs: [["Synthetic ", "clinic ", "handout."], [], ["Second paragraph & more."]],
                title: "A Synthetic Word Document", deflate: deflate)
            let document = try await extract(data, name: "handout.docx")
            XCTAssertEqual(
                document.text,
                "Synthetic clinic handout.\n\nSecond paragraph & more.\n\nTab\tand\nbreak",
                "deflate=\(deflate)")
            XCTAssertEqual(document.title, "A Synthetic Word Document")
            XCTAssertFalse(document.text.contains("deleted words"), "tracked deletions are skipped")
            XCTAssertFalse(document.text.contains("PAGE"), "field codes are skipped")
        }
    }

    func testMalformedDOCXFailsClearly() async {
        await assertFails(
            Data("not a zip at all".utf8), name: "fake.docx",
            with: .malformed(.docx, "it is not a Word (.docx) file."))
        let noBody = SyntheticZip.make([("hello.txt", Data("hi".utf8))])
        await assertFails(
            noBody, name: "nobody.docx", with: .malformed(.docx, "it has no document body (word/document.xml)."))
        let good = SyntheticDOCX.make(paragraphs: [["Synthetic text"]])
        await assertFails(
            good.prefix(good.count / 2), name: "truncated.docx",
            with: .malformed(.docx, "it is not a Word (.docx) file."))
        let badXML = SyntheticZip.make([("word/document.xml", Data("<w:document><w:p>".utf8))])
        await assertFails(
            badXML, name: "badxml.docx", with: .malformed(.docx, "its document body is not valid XML."))
    }

    func testZipReaderChecksCRC() throws {
        var archive = SyntheticZip.make([("word/document.xml", Data("<a/>".utf8))], deflate: false)
        // Flip one byte of the stored entry's content (right after its 30-byte header and 17-byte name).
        archive[30 + 17] ^= 0xFF
        let reader = try ZipArchiveReader(data: archive)
        XCTAssertThrowsError(try reader.contents(of: "word/document.xml")) { error in
            XCTAssertEqual(error as? ZipArchiveReader.ZipError, .damaged("an entry failed its checksum"))
        }
        XCTAssertEqual(CRC32.checksum(Data("123456789".utf8)), 0xCBF4_3926, "the standard check value")
    }

    func testEntitiesDecode() {
        XCTAssertEqual(
            HTMLEntities.decode("a &amp; b &lt;c&gt; &#39;d&#39; &#x1F600; &bogus; &"), "a & b <c> 'd' 😀 &bogus; &")
    }
}
