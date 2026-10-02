import ChirpCore
import Foundation
import XCTest

@testable import ChirpExport

/// Review R1-9 (plan 024 Task 4): export file names. A file name holds 255 units — on Apple's file systems UTF-16
/// units of the *decomposed* name (measured: 251 kanji write, 251 Hangul syllables or "é"s do not, because each
/// decomposes), on Linux 255 UTF-8 bytes — and the two exporters each had their own rule (no limit, and 120
/// characters), so a long title made Share fail with "file name too long". One helper now names every export.
final class ExportFileNameTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ExportFileNameTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    /// Titles a person can reach: a long rename, a 200-character PDF title in a script that decomposes, emoji.
    private static let longTitles = [
        String(repeating: "Synthetic follow-up visit ", count: 12),
        String(repeating: "환자기록", count: 40),
        String(repeating: "患者記録", count: 70),
        String(repeating: "é", count: 200),
        String(repeating: "😀", count: 150),
    ]

    func testALongTitleStillWritesInBothExporters() throws {
        for title in Self.longTitles {
            var row = Transcription(fileName: "visit.m4a", status: .completed)
            row.titleOverride = title
            row.rawTranscript = "Synthetic text."
            let text = try TranscriptExporter(cleanupMode: .raw).write(row, as: .json, to: folder)
            let page = try DocumentExporter().write(
                ExportDocument.text(title: title, body: "Synthetic text."), as: .docx, to: folder)
            for url in [text, page] {
                XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "\(title.prefix(12))…")
                let stem = url.deletingPathExtension().lastPathComponent
                XCTAssertTrue(title.hasPrefix(stem), "the name is the title cut on a character boundary")
                XCTAssertLessThanOrEqual(Self.largestUTF8Count(stem), ExportFileName.maxStemBytes)
            }
        }
    }

    func testOneRuleNamesEveryExport() {
        XCTAssertEqual(ExportFileName.stem(fromTitle: "Plan: Q3/Q4", fallback: "document"), "Plan  Q3 Q4")
        XCTAssertEqual(ExportFileName.stem(fromTitle: "Notes\\Ideas\0", fallback: "document"), "Notes Ideas")
        XCTAssertEqual(ExportFileName.stem(fromTitle: "  \n ", fallback: "transcript"), "transcript")
        XCTAssertEqual(
            ExportFileName.stem(fromTitle: "Client Q&A v2.1", fallback: "transcript"), "Client Q&A v2.1",
            "a title that looks like it ends in an extension keeps it")
        XCTAssertEqual(
            ExportFileName.stem(fromTitle: "Short title", fallback: "transcript"), "Short title", "short titles are whole")
    }

    /// A cut never splits a character: a combining accent stays with its letter, an emoji family stays whole, and
    /// a space left at the cut is trimmed.
    func testTheCutKeepsWholeCharacters() {
        let family = "👨‍👩‍👧"
        let stem = ExportFileName.stem(fromTitle: String(repeating: family, count: 30), fallback: "x")
        XCTAssertTrue(stem.allSatisfy { $0 == Character(family) })
        XCTAssertLessThanOrEqual(Self.largestUTF8Count(stem), ExportFileName.maxStemBytes)

        let accents = ExportFileName.stem(fromTitle: String(repeating: "e\u{301} ", count: 100), fallback: "x")
        XCTAssertFalse(accents.hasSuffix(" "))
        XCTAssertTrue(accents.hasSuffix("e\u{301}"))
    }

    private static func largestUTF8Count(_ text: String) -> Int {
        max(text.precomposedStringWithCanonicalMapping.utf8.count, text.decomposedStringWithCanonicalMapping.utf8.count)
    }
}
