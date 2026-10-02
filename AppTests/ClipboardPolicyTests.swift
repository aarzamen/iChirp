import UIKit
import XCTest

@testable import iChirp

/// Review R6a-1 and R6b-2: content text reaches the pasteboard only local-only (never Universal Clipboard), the
/// dictation clipboard included, and the share sheet never offers iOS's own Copy (which would write the general
/// pasteboard).
@MainActor
final class ClipboardPolicyTests: XCTestCase {
    /// Records what a copy writes.
    private final class RecordingPasteboard: PasteboardItemsWriting {
        var items: [[String: Any]] = []
        var options: [UIPasteboard.OptionsKey: Any] = [:]

        func setItems(_ items: [[String: Any]], options: [UIPasteboard.OptionsKey: Any]) {
            self.items = items
            self.options = options
        }
    }

    func testDictationClipboardIsLocalOnlyPlainText() {
        let pasteboard = RecordingPasteboard()
        SystemClipboard(pasteboard: pasteboard).copy("Synthetic dictation 7731")
        XCTAssertEqual(
            pasteboard.options[.localOnly] as? Bool, true, "dictation text must not reach Universal Clipboard")
        XCTAssertEqual(pasteboard.items.count, 1)
        XCTAssertEqual(pasteboard.items.first?["public.plain-text"] as? String, "Synthetic dictation 7731")
    }

    func testContentCopyIsLocalOnly() {
        let pasteboard = RecordingPasteboard()
        ContentClipboard.copy("Synthetic transcript", to: pasteboard)
        XCTAssertEqual(pasteboard.options[.localOnly] as? Bool, true)
    }

    func testShareSheetLeavesOutTheSystemCopy() {
        let controller = ActivityView.makeController(items: ["Synthetic text"])
        XCTAssertTrue(controller.excludedActivityTypes?.contains(.copyToPasteboard) == true)
    }

    /// Every write to the general pasteboard in `App/Sources` is local-only, except the listed non-content ones.
    func testEveryGeneralPasteboardWriteIsLocalOnlyOrListed() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let root = repo.appendingPathComponent("App/Sources")
        // file → why its general-pasteboard use is not content (each is checked by count, so a new one fails).
        let allowed: [String: (count: Int, why: String)] = [
            "SharedViews.swift": (1, "the launch error's details and build, for the developer"),
            "AboutSection.swift": (1, "the build details"),
            "StructureEvalScreen.swift": (1, "the synthetic evaluation report"),
        ]
        var unexpected: [String] = []
        var counts: [String: Int] = [:]
        var scanned = 0
        let files = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        for case let file as URL in files where file.pathExtension == "swift" {
            scanned += 1
            let code = try String(contentsOf: file, encoding: .utf8)
                .components(separatedBy: "\n")
                .map { line in line.range(of: "//").map { String(line[..<$0.lowerBound]) } ?? line }
                .joined(separator: "\n")
            var searchStart = code.startIndex
            while let found = code.range(of: "UIPasteboard.general", range: searchStart..<code.endIndex) {
                searchStart = found.upperBound
                let after = String(code[found.upperBound...].prefix(160))
                if after.hasPrefix(".setItems("), after.contains(".localOnly: true") { continue }
                // Passed along as a value (the local-only writer's default destination), not written here.
                if after.hasPrefix(")") || after.hasPrefix(",") { continue }
                let name = file.lastPathComponent
                counts[name, default: 0] += 1
                if allowed[name] == nil { unexpected.append("\(name): UIPasteboard.general\(after.prefix(40))") }
            }
        }
        XCTAssertGreaterThan(scanned, 50, "the scan found the app sources")
        XCTAssertEqual(unexpected, [], "content copies go through ContentClipboard (local-only)")
        for (name, rule) in allowed {
            XCTAssertLessThanOrEqual(counts[name] ?? 0, rule.count, "\(name): only \(rule.why)")
        }
    }
}
