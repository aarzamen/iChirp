import XCTest

@testable import ChirpText

final class PromptTemplateRendererTests: XCTestCase {
    func testSubstitutesBothVariables() {
        let rendered = PromptTemplateRenderer.render(
            "Notes: {{userNotes}}\nTranscript: {{transcript}}",
            substitutions: [.userNotes: "bring the heron photos", .transcript: "Speaker 1: hello"])
        XCTAssertEqual(rendered, "Notes: bring the heron photos\nTranscript: Speaker 1: hello")
    }

    func testValuesAreNeverRenderedAsTemplates() {
        let rendered = PromptTemplateRenderer.render(
            "A {{transcript}} B {{userNotes}}",
            substitutions: [.transcript: "says {{userNotes}} literally", .userNotes: "NOTES"])
        XCTAssertEqual(rendered, "A says {{userNotes}} literally B NOTES")
    }

    func testUnknownAndMissingKeysRenderEmptyAndUnterminatedMarkerIsLiteral() {
        XCTAssertEqual(PromptTemplateRenderer.render("x{{Usernotes}}y", substitutions: [:]), "xy")
        XCTAssertEqual(PromptTemplateRenderer.render("x{{transcript}}y", substitutions: [:]), "xy")
        XCTAssertEqual(PromptTemplateRenderer.render("keep {{ this", substitutions: [:]), "keep {{ this")
        XCTAssertEqual(PromptTemplateRenderer.render("no tokens", substitutions: [.transcript: "t"]), "no tokens")
    }

    func testReferences() {
        XCTAssertTrue(PromptTemplateRenderer.references(.transcript, in: "Use {{transcript}}"))
        XCTAssertFalse(PromptTemplateRenderer.references(.userNotes, in: "Use {{transcript}}"))
    }
}
