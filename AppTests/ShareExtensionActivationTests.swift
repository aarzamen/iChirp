import Foundation
import XCTest

/// Plan 029, device QA 4 (2026-10-27): the share extension took over the share sheet's Parakeet icon for a Voice Memos
/// recording (it shares the file plus its title as text), found no link and did nothing, so "Open in Parakeet" for
/// files was gone. Its activation rule must take a web link or text, and never a share that carries a file.
final class ShareExtensionActivationTests: XCTestCase {
    private func rule() throws -> NSPredicate {
        let appex = try XCTUnwrap(Bundle.main.builtInPlugInsURL?.appendingPathComponent("iChirpShare.appex"))
        let info = try XCTUnwrap(NSDictionary(contentsOf: appex.appendingPathComponent("Info.plist")))
        let ext = try XCTUnwrap(info["NSExtension"] as? [String: Any])
        let attributes = try XCTUnwrap(ext["NSExtensionAttributes"] as? [String: Any])
        let format = try XCTUnwrap(
            attributes["NSExtensionActivationRule"] as? String, "a predicate string, not the dictionary shorthand")
        return NSPredicate(format: format)
    }

    private func share(_ attachments: [[String]]) -> [String: Any] {
        [
            "extensionItems": [
                ["attachments": attachments.map { ["registeredTypeIdentifiers": $0] }]
            ]
        ]
    }

    func testTakesAWebLink() throws {
        XCTAssertTrue(try rule().evaluate(with: share([["public.url"]])))
    }

    func testTakesTextWithALink() throws {
        XCTAssertTrue(try rule().evaluate(with: share([["public.plain-text"]])))
        XCTAssertTrue(try rule().evaluate(with: share([["public.url"], ["public.plain-text"]])))
    }

    /// The file and its title as two separate items (one attachment each): the whole share is left to Open in.
    func testLeavesAFileSharedWithItsTitleAsASecondItem() throws {
        let share: [String: Any] = [
            "extensionItems": [
                ["attachments": [["registeredTypeIdentifiers": ["com.apple.m4a-audio", "public.file-url"]]]],
                ["attachments": [["registeredTypeIdentifiers": ["public.plain-text"]]]],
            ]
        ]
        XCTAssertFalse(try rule().evaluate(with: share))
    }

    func testLeavesAVoiceMemoToOpenInParakeet() throws {
        XCTAssertFalse(
            try rule().evaluate(with: share([["com.apple.m4a-audio", "public.file-url"], ["public.plain-text"]])))
        XCTAssertFalse(try rule().evaluate(with: share([["public.file-url"]])))
        XCTAssertFalse(try rule().evaluate(with: share([["public.mpeg-4"]])))
        XCTAssertFalse(try rule().evaluate(with: share([["com.adobe.pdf", "public.file-url"]])))
    }

    /// Final review I4: a document file that comes without a file URL (only its own type) stays with Open in.
    func testLeavesDocumentFilesToOpenInParakeet() throws {
        XCTAssertFalse(try rule().evaluate(with: share([["net.daringfireball.markdown"]])))
        XCTAssertFalse(try rule().evaluate(with: share([["public.rtf"]])))
        XCTAssertFalse(try rule().evaluate(with: share([["public.html"]])))
        XCTAssertFalse(try rule().evaluate(with: share([["org.openxmlformats.wordprocessingml.document"]])))
    }
}
