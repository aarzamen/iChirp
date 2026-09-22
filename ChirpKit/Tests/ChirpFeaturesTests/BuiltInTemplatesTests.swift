import ChirpCore
import XCTest

@testable import ChirpFeatures

final class BuiltInTemplatesTests: XCTestCase {
    func testTheNineShippedTemplates() {
        XCTAssertEqual(
            BuiltInTemplates.all.map(\.name),
            ["Summary", "Meeting notes", "Action items", "Agenda", "SOAP note", "Polish", "Distill", "Decide", "Brief"])
        XCTAssertEqual(Set(BuiltInTemplates.all.map(\.id)).count, 9)
        XCTAssertEqual(Set(BuiltInTemplates.all.map(\.canonicalKey)).count, 9)
        XCTAssertEqual(
            BuiltInTemplates.all.filter { $0.category == .transform }.map(\.canonicalKey),
            ["polish", "distill", "decide", "brief"])
        for template in BuiltInTemplates.all {
            XCTAssertFalse(template.content.contains("                "), "\(template.name) keeps source indentation")
            XCTAssertGreaterThan(template.revision, 0)
        }
    }

    func testCanonicalKeysAreStable() {
        XCTAssertEqual(
            BuiltInTemplates.all.map(\.canonicalKey),
            [
                "summary", "meeting-notes", "action-items", "agenda", "soap-note", "polish", "distill", "decide",
                "brief",
            ])
    }

    func testOnlySOAPRaisesItsOutputToClinical() {
        XCTAssertEqual(BuiltInTemplates.soapNote.outputPrivacyClass, .clinical)
        XCTAssertEqual(BuiltInTemplates.all.filter { $0.outputPrivacyClass != nil }.map(\.canonicalKey), ["soap-note"])
        XCTAssertTrue(BuiltInTemplates.soapNote.content.contains("Not documented"))
        XCTAssertTrue(BuiltInTemplates.soapNote.content.contains("never invent"))
    }
}
