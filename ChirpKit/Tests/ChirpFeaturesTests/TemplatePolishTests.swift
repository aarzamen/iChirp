import ChirpCore
import Foundation
import XCTest

@testable import ChirpFeatures

/// Plan 026 polish round: a Hide started outside the Templates screen (the Transforms tab's context menu) can say
/// whether it worked, so that screen can show the error; and each draft problem names the field that owns it, so the
/// editor shows the sentence under that field. Every text is synthetic.
@MainActor
final class TemplatePolishTests: XCTestCase {
    func testSetVisibleSaysWhetherItWorked() async throws {
        let store = FakeDeliverableStore()
        try await store.installBuiltInTemplates(BuiltInTemplates.all)
        let library = TemplateLibraryViewModel(store: store, recipesUsing: { _ in [] }, didChange: {})
        await library.load()
        let agenda = try XCTUnwrap(library.documents.first { $0.id == BuiltInTemplates.agenda.id })

        await store.failNextWrite(with: TemplateLibraryError.templateNotFound)
        let failed = await library.setVisible(agenda, false)
        XCTAssertFalse(failed)
        XCTAssertEqual(library.actionError, "This template no longer exists.")

        library.dismissActionError()
        let worked = await library.setVisible(agenda, false)
        XCTAssertTrue(worked)
        XCTAssertNil(library.actionError)
    }

    func testEachProblemNamesTheFieldThatOwnsIt() {
        let nameProblems: [TemplateDraft.Problem] = [.emptyName, .nameTooLong, .duplicateName("SOAP note")]
        let instructionProblems: [TemplateDraft.Problem] = [
            .emptyInstructions, .instructionsTooLong(count: 4_001), .reservedTag("<transcript>"),
        ]
        for problem in nameProblems { XCTAssertEqual(problem.field, .name, "\(problem)") }
        for problem in instructionProblems { XCTAssertEqual(problem.field, .instructions, "\(problem)") }
    }
}
