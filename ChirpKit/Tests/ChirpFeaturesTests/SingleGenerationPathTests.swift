import Foundation
import XCTest

/// Enforces "DeliverableService is the only path from a transcript to a LanguageModel": no other file in
/// ChirpFeatures or the app calls `LanguageModel.generate` directly (engine targets implement it; they are not
/// scanned). Calls to `DeliverableService.generate(templateID:…)` are the allowed way in.
final class SingleGenerationPathTests: XCTestCase {
    func testOnlyDeliverableServiceCallsLanguageModelGenerate() throws {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let roots = ["ChirpKit/Sources/ChirpFeatures", "App/Sources"].map { repo.appendingPathComponent($0) }
        let direct = try NSRegularExpression(pattern: #"\.generate\((?!\s*templateID:)"#)
        var offenders: [String] = []
        var scanned = 0
        for root in roots {
            guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { continue }
            for case let file as URL in files where file.pathExtension == "swift" {
                scanned += 1
                guard file.lastPathComponent != "DeliverableService.swift" else { continue }
                let source = try String(contentsOf: file, encoding: .utf8)
                let range = NSRange(source.startIndex..., in: source)
                if direct.firstMatch(in: source, range: range) != nil {
                    offenders.append(file.lastPathComponent)
                }
            }
        }
        XCTAssertGreaterThan(scanned, 10, "the scan found the sources")
        XCTAssertEqual(offenders, [], "only DeliverableService may call LanguageModel.generate")
    }
}
