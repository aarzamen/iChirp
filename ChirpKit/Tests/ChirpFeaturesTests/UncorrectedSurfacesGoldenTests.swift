import ChirpCore
import ChirpText
import Foundation
import XCTest

@testable import ChirpFeatures

/// Plan 025 Step A0: pins, for the plan 024 Task 8 fixtures (`TranscriptTextGoldenTests.fixtures`) in Raw and Clean,
/// the surfaces that golden does not cover — the accessor's `.heard` and `.shown(mode)` lines, its whole texts, the
/// Transcript screen's paragraphs and Extract fields' source text — so corrections (plan 025) change nothing for a row
/// without them. Recorded on the code before any Part A change. Synthetic content only.
///
/// Goldens: `Fixtures/UncorrectedSurfacesGoldens/<fixture>-<mode>.txt`. To re-record after an intended change:
/// `CHIRP_RECORD_GOLDENS=1 swift test --package-path ChirpKit --filter UncorrectedSurfacesGoldenTests`, then review the
/// diff and explain every change.
@MainActor
final class UncorrectedSurfacesGoldenTests: XCTestCase {
    private static func describe(_ lines: [TranscriptTextLine]) -> String {
        lines.map { line in
            let time = line.startMs.map { "\($0)-\(line.endMs ?? 0)" } ?? "untimed"
            let speaker = line.speakerLabel.map { " \($0)" } ?? ""
            return "#\(line.id) \(time) words \(line.wordRange)\(speaker): \(line.text)"
        }.joined(separator: "\n")
    }

    private func render(_ row: Transcription, mode: CleanupMode) async -> String {
        var settingsValue = TranscriptionSettings()
        settingsValue.cleanupMode = mode
        let viewModel = TranscriptViewModel(
            id: row.id, store: FakeStore(rows: [row]), paths: AppPaths(root: FileManager.default.temporaryDirectory),
            settings: InMemorySettingsStore(settingsValue))
        await viewModel.load()
        let heard = row.text(.heard)
        let shown = row.text(.shown(mode))
        let paragraphs = viewModel.paragraphs.map { "\($0.startMs)-\($0.endMs) \($0.speakerId ?? "-"): \($0.text)" }
        let sections: [(String, String)] = [
            ("heard lines", Self.describe(heard.lines)),
            ("heard text", heard.plainText),
            ("heard text without lines", row.plainText(.heard)),
            ("shown lines", Self.describe(shown.lines)),
            ("shown text", shown.plainText),
            ("shown text without lines", row.plainText(.shown(mode))),
            ("tokens", heard.tokens.map { "\($0.text)@\($0.startMs)" }.joined(separator: " ")),
            ("screen paragraphs", paragraphs.joined(separator: "\n")),
            ("extract fields source", StructuredSourceText(transcription: row).text),
        ]
        return sections.map { "=== \($0.0) ===\n\($0.1)\n" }.joined(separator: "\n")
    }

    private func goldenURL(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/UncorrectedSurfacesGoldens/\(name).txt")
    }

    func testEverySurfaceMatchesItsGolden() async throws {
        let record = ProcessInfo.processInfo.environment["CHIRP_RECORD_GOLDENS"] == "1"
        for (name, row) in TranscriptTextGoldenTests.fixtures {
            for mode in CleanupMode.allCases {
                let actual = await render(row, mode: mode)
                let url = goldenURL("\(name)-\(mode.rawValue)")
                if record {
                    try FileManager.default.createDirectory(
                        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try actual.write(to: url, atomically: true, encoding: .utf8)
                    continue
                }
                let expected = try String(contentsOf: url, encoding: .utf8)
                XCTAssertEqual(actual, expected, "\(name)-\(mode.rawValue)")
            }
        }
    }
}
