// Ported from MacParakeet (GPL-3.0): Tests/MacParakeetTests/TextProcessing/TextRefinementServiceTests.swift @ bbae9e0e
// Changes: `TextRefinementService.refine` (async, returns `TextRefinementResult{text,path,postPasteAction}`,
// `Dictation.ProcessingMode`) → `TextRefinement.refine` (sync, returns `String?`, ChirpCore's
// `CleanupMode`) — the M0/M1 surface pinned by the implementation plan. Skipped (feature not carried
// into the reduced signature, no `insertionStyle` parameter or `postPasteAction`/`path` result):
// `testRawModeExtractsActionButSkipsOtherProcessing`, `testRawModeNoActionWhenNoTrigger`,
// `testRawModeSkipsTextSnippets` (raw mode now unconditionally returns nil — trailing action
// extraction on the raw path was not ported), `testDeterministicModeReturnsAction` (no
// `postPasteAction` in the result), `testDeterministicModeHonorsInlineInsertionStyle` (no
// `insertionStyle` parameter — `TextProcessingPipeline` itself still supports it, see
// `TextProcessingPipelineTests`).

@testable import ChirpText
import ChirpCore
import XCTest

final class TextRefinementServiceTests: XCTestCase {
    func testCleanModeReturnsDeterministicText() {
        let service = TextRefinement()
        let result = service.refine(
            rawText: "uh hello world",
            mode: .clean,
            customWords: [],
            snippets: []
        )

        XCTAssertEqual(result, "Hello world")
    }

    func testRawModeReturnsNilText() {
        let service = TextRefinement()
        let result = service.refine(
            rawText: "um hello world",
            mode: .raw,
            customWords: [],
            snippets: []
        )

        XCTAssertNil(result, "Raw mode returns nil (no processing applied)")
    }

    func testCleanModeStripsUmByDefaultAndPreservesWhenDisabled() {
        let service = TextRefinement()
        let stripped = service.refine(
            rawText: "I um think we should ship it",
            mode: .clean,
            customWords: [],
            snippets: []
        )
        XCTAssertEqual(stripped, "I think we should ship it")

        let preserved = service.refine(
            rawText: "um, dois, três",
            mode: .clean,
            customWords: [],
            snippets: [],
            removeUmFiller: false
        )
        XCTAssertEqual(preserved, "Um, dois, três")
    }
}
