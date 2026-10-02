import Foundation
import XCTest

@testable import ChirpCore

/// Plan 026 Step 1: the rules a template of your own must meet before it is saved (the store re-checks them).
final class TemplateDraftTests: XCTestCase {
    private func draft(
        name: String = "Clinic SOAP",
        category: PromptTemplate.Category = .deliverable,
        instructions: String = "Write a SOAP note with these headings.",
        clinical: Bool = false
    ) -> TemplateDraft {
        TemplateDraft(name: name, category: category, instructions: instructions, makesClinicalDocuments: clinical)
    }

    func testANameAndInstructionsAreRequired() {
        XCTAssertEqual(draft(name: "").problem(takenNames: []), .emptyName)
        XCTAssertEqual(draft(name: "  \n ").problem(takenNames: []), .emptyName)
        XCTAssertEqual(draft(instructions: "").problem(takenNames: []), .emptyInstructions)
        XCTAssertEqual(draft(instructions: " \n\t ").problem(takenNames: []), .emptyInstructions)
        XCTAssertNil(draft().problem(takenNames: []))
        XCTAssertEqual(TemplateDraft.Problem.emptyName.sentence, "Give the template a name.")
        XCTAssertEqual(TemplateDraft.Problem.emptyInstructions.sentence, "Write the instructions first.")
    }

    func testANameIsOneLineTrimmedAndAtMost40Characters() {
        XCTAssertEqual(draft(name: "  Clinic\nSOAP \n").cleanedName, "Clinic SOAP")
        XCTAssertEqual(draft(name: "Referral\r\n\r\nletter").cleanedName, "Referral letter")
        let forty = String(repeating: "a", count: 40)
        XCTAssertNil(draft(name: "  " + forty + "  ").problem(takenNames: []))
        XCTAssertEqual(draft(name: forty + "b").problem(takenNames: []), .nameTooLong)
        XCTAssertEqual(TemplateDraft.Problem.nameTooLong.sentence, "A name can be up to 40 characters.")
        XCTAssertEqual(TemplateLimits.maxNameLength, 40)
    }

    func testANameTakenByAnotherTemplateIsRefusedIgnoringCase() {
        let taken = ["SOAP note", "Summary"]
        XCTAssertEqual(draft(name: "soap NOTE").problem(takenNames: taken), .duplicateName("SOAP note"))
        XCTAssertEqual(draft(name: " Summary ").problem(takenNames: taken), .duplicateName("Summary"))
        XCTAssertEqual(
            TemplateDraft.Problem.duplicateName("SOAP note").sentence,
            "“SOAP note” is already a template. Choose another name.")
        // Renaming yourself to another case: the caller leaves your own name out of `takenNames`.
        XCTAssertNil(draft(name: "clinic soap").problem(takenNames: taken))
    }

    func testInstructionsAreAtMost4000Characters() {
        XCTAssertEqual(TemplateLimits.maxInstructionCharacters, 4_000)
        XCTAssertNil(draft(instructions: String(repeating: "x", count: 4_000)).problem(takenNames: []))
        XCTAssertNil(draft(instructions: "\n " + String(repeating: "x", count: 4_000) + " \n").problem(takenNames: []))
        let long = draft(instructions: String(repeating: "x", count: 4_312))
        XCTAssertEqual(long.problem(takenNames: []), .instructionsTooLong(count: 4_312))
        XCTAssertEqual(long.characterCount, 4_312)
        XCTAssertEqual(
            TemplateDraft.Problem.instructionsTooLong(count: 4_312).sentence,
            "Instructions can be up to 4,000 characters; these are 4,312. Shorter instructions leave more room for the "
                + "transcript.")
    }

    func testInstructionsCannotUseTheTagsThatMarkTheSource() {
        let refused: [(String, String)] = [
            ("Use the <transcript> below.", "<transcript>"),
            ("End at </Transcript> please.", "<transcript>"),
            ("Read <user_notes first", "<user_notes>"),
            ("<task>Summarize</task>", "<task>"),
            ("Wrap it in <document>.", "<document>"),
            ("Parts look like <TRANSCRIPT_PART index=1>", "<transcript_part>"),
            ("Notes: <transcript_notes>", "<transcript_notes>"),
        ]
        for (text, tag) in refused {
            XCTAssertEqual(draft(instructions: text).problem(takenNames: []), .reservedTag(tag), text)
        }
        for text in ["If a < b, say so.", "Bold with <b>like this</b>.", "List <tasks> and <documents>.", "x<y"] {
            XCTAssertNil(draft(instructions: text).problem(takenNames: []), text)
        }
        XCTAssertEqual(
            TemplateDraft.Problem.reservedTag("<transcript>").sentence,
            "Remove “<transcript>” from the instructions: Parakeet uses it to mark the transcript and your notes.")
    }

    func testNeutralizingReplacesOnlyTheReservedOpeners() {
        let text = "Keep <b> and a < b. Not <Transcript> or </task> or <user_notes x>."
        XCTAssertEqual(
            TemplateLimits.neutralizingReservedTags(in: text),
            "Keep <b> and a < b. Not ‹Transcript> or ‹/task> or ‹user_notes x>.")
        XCTAssertEqual(TemplateLimits.neutralizingReservedTags(in: "plain"), "plain")
    }

    func testTheClinicalSwitchOnlyEverRaises() {
        XCTAssertEqual(draft(clinical: true).outputPrivacyClass, .clinical)
        XCTAssertNil(draft(clinical: false).outputPrivacyClass)
        for clinical in [true, false] {
            let value = draft(clinical: clinical).outputPrivacyClass
            XCTAssertTrue(value == nil || value == .clinical)
        }
    }

    func testCopyNamesAreFreeAndFit() {
        XCTAssertEqual(TemplateNaming.copyName(of: "SOAP note", taken: ["SOAP note"]), "SOAP note copy")
        XCTAssertEqual(
            TemplateNaming.copyName(of: "SOAP note", taken: ["SOAP note", "soap note COPY"]), "SOAP note copy 2")
        XCTAssertEqual(
            TemplateNaming.copyName(of: "SOAP note", taken: ["SOAP note", "SOAP note copy", "SOAP note copy 2"]),
            "SOAP note copy 3")
        let forty = String(repeating: "a", count: 40)
        let copy = TemplateNaming.copyName(of: forty, taken: [forty])
        XCTAssertEqual(copy, String(repeating: "a", count: 35) + " copy")
        XCTAssertEqual(copy.count, 40)
        let second = TemplateNaming.copyName(of: forty, taken: [forty, copy])
        XCTAssertEqual(second, String(repeating: "a", count: 33) + " copy 2")
        XCTAssertLessThanOrEqual(second.count, 40)
        // A trimmed base never ends in a space.
        let spaced = String(repeating: "a", count: 34) + " bcdef"
        XCTAssertEqual(TemplateNaming.copyName(of: spaced, taken: []), String(repeating: "a", count: 34) + " copy")
    }

    func testRestoredNames() {
        XCTAssertEqual(TemplateNaming.restoredName(of: "Clinic SOAP", taken: ["Summary"]), "Clinic SOAP")
        XCTAssertEqual(TemplateNaming.restoredName(of: "Clinic SOAP", taken: ["clinic soap"]), "Clinic SOAP (restored)")
        XCTAssertEqual(
            TemplateNaming.restoredName(of: "Clinic SOAP", taken: ["Clinic SOAP", "Clinic SOAP (Restored)"]),
            "Clinic SOAP (restored 2)")
        let forty = String(repeating: "a", count: 40)
        let restored = TemplateNaming.restoredName(of: forty, taken: [forty])
        XCTAssertEqual(restored, String(repeating: "a", count: 29) + " (restored)")
        XCTAssertEqual(restored.count, 40)
    }

    func testATemplateIsShownUnlessHidden() throws {
        let shown = PromptTemplate(name: "Mine", category: .deliverable, activeVersionID: UUID())
        XCTAssertTrue(shown.isVisible)
        var hidden = shown
        hidden.isVisible = false
        XCTAssertFalse(hidden.isVisible)

        // A template encoded before plan 026 (no isVisible key) decodes as shown.
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(shown)) as? [String: Any])
        object.removeValue(forKey: "isVisible")
        let old = try JSONDecoder().decode(PromptTemplate.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertTrue(old.isVisible)
        XCTAssertEqual(try JSONDecoder().decode(PromptTemplate.self, from: JSONEncoder().encode(hidden)), hidden)
    }

    func testDraftsOfATemplateCarryItsKindTextAndSwitch() {
        let soap = PromptTemplate(
            name: "SOAP note", category: .deliverable, isBuiltIn: true, outputPrivacyClass: .clinical,
            activeVersionID: UUID())
        let fromSOAP = TemplateDraft(template: soap, instructions: "Use S, O, A, P.")
        XCTAssertEqual(fromSOAP.name, "SOAP note")
        XCTAssertEqual(fromSOAP.category, .deliverable)
        XCTAssertEqual(fromSOAP.instructions, "Use S, O, A, P.")
        XCTAssertTrue(fromSOAP.makesClinicalDocuments)
        let polish = PromptTemplate(name: "Polish", category: .transform, activeVersionID: UUID())
        XCTAssertFalse(TemplateDraft(template: polish, instructions: "x").makesClinicalDocuments)
    }

    func testLibraryErrorsAreSentences() {
        XCTAssertEqual(
            TemplateLibraryError.builtInIsReadOnly.errorDescription,
            "Built-in templates can’t be changed. Duplicate it to make your own.")
        XCTAssertEqual(TemplateLibraryError.templateNotFound.errorDescription, "This template no longer exists.")
        XCTAssertEqual(
            TemplateLibraryError.templateDeleted.errorDescription, "This template was deleted. Restore it first.")
        XCTAssertEqual(
            TemplateLibraryError.invalidOrder.errorDescription, "The order could not be saved. Nothing changed.")
        XCTAssertEqual(
            TemplateLibraryError.problem(.emptyName).errorDescription, TemplateDraft.Problem.emptyName.sentence)
    }
}
