import ChirpCore
import ChirpFeatures
import SwiftUI
import XCTest

@testable import iChirp

/// Polish lane u2 (UX audit, Create and Transforms), the app side: typed text is never lost to a dismissal (F19, F24),
/// Done never drops a running Transform (F38), honest copy (F25, F35, F41) and the helpers behind the screens.
@MainActor
final class PolishCreateAppTests: XCTestCase {
    // MARK: - Never lose typed text (F19, F24)

    func testCancelAsksOnlyWhenSomethingWasTyped() {
        XCTAssertEqual(DiscardDecision.onCancel(hasInput: false), .close)
        XCTAssertEqual(DiscardDecision.onCancel(hasInput: true), .ask)
        XCTAssertFalse(DiscardDecision.holdsInput(""))
        XCTAssertFalse(DiscardDecision.holdsInput("  \n\t "), "whitespace alone is not input")
        XCTAssertTrue(DiscardDecision.holdsInput("Synthetic note"))
    }

    func testTheCreateDraftKnowsWhenClosingWouldLoseTextOrALink() {
        var draft = CreateDraft(choices: CreateChoices(input: .text, output: .summary))
        XCTAssertFalse(draft.hasUnsavedInput)
        draft.text = "Synthetic plan"
        XCTAssertTrue(draft.hasUnsavedInput)
        draft.text = ""
        draft.input = .link
        draft.link = "https://example.com/synthetic.mp3"
        XCTAssertTrue(draft.hasUnsavedInput)
        draft.input = .speak
        XCTAssertTrue(draft.hasUnsavedInput, "a link typed before switching to Speak still counts")
    }

    // MARK: - Done never drops a running Transform (F38)

    func testDoneAsksWhileARunIsWritingAndClosesOtherwise() {
        XCTAssertEqual(TransformRunView.doneDecision(.checking), .ask)
        XCTAssertEqual(TransformRunView.doneDecision(.running(.writing)), .ask)
        XCTAssertEqual(TransformRunView.doneDecision(.running(.reading(part: 1, of: 3))), .ask)
        XCTAssertEqual(TransformRunView.doneDecision(.idle), .close, "declined: nothing to lose")
        XCTAssertEqual(TransformRunView.doneDecision(.failed("Synthetic failure.")), .close)
    }

    func testTheDoneQuestionIsWiredToStopThenClose() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: repo.appendingPathComponent("App/Sources/Screens/Transforms/TransformRunView.swift"),
            encoding: .utf8)
        XCTAssertTrue(source.contains(".interactiveDismissDisabled(RunStatus.isActive(run.phase))"))
        XCTAssertTrue(source.contains("switch Self.doneDecision(run.phase)"))
        XCTAssertTrue(source.contains(#"Button("Stop and Close", role: .destructive)"#))
    }

    // MARK: - Honest copy

    func testTypeOrPasteOnlyPromisesWhatTheTextScreenHas() {
        XCTAssertFalse(TextItemSheet.footer.contains("Ask"), "the text item screen has no Ask (F25)")
        XCTAssertTrue(TextItemSheet.footer.contains("Transform"))
    }

    func testTheModelRowHidesAppleInternalIdentifier() {
        XCTAssertNil(DeliverableDetailScreen.modelLabel("apple-on-device"), "F35: the Provider row says it")
        XCTAssertNil(DeliverableDetailScreen.modelLabel(nil))
        XCTAssertNil(DeliverableDetailScreen.modelLabel("  "))
        XCTAssertEqual(DeliverableDetailScreen.modelLabel("synthetic-model-7b"), "synthetic-model-7b")

        let document = Deliverable(
            transcriptionID: UUID(), promptID: nil, promptVersionID: nil, title: "Summary", engineID: "apple.fm",
            provider: "Apple on-device model", model: "apple-on-device", locality: .onDevice, text: "Synthetic.",
            privacyClass: .personal)
        let rows = DeliverableDetailScreen.metadata(document, versionNumber: 1, sourceTitle: "Synthetic")
        XCTAssertFalse(rows.contains { $0.0 == "Model" })
        XCTAssertEqual(rows.first?.0, "From")
    }

    func testTheModelChipNamesTheModelOnThisIPhone() {
        XCTAssertEqual(LanguageModelChoice.onDevice.placeWithName, "on this iPhone · Apple on-device model")
        let cloud = LanguageModelChoice(
            source: .provider(UUID()), name: "Claude", locality: .cloud, host: "api.example.com",
            isTrustedForClinical: false)
        XCTAssertEqual(cloud.placeWithName, "in the cloud (Claude)", "the place already names it")
    }

    func testCreateTilesGoToOneColumnAtLargeText() {
        XCTAssertEqual(CreateOptionTile.columns(for: .large), 2)
        XCTAssertEqual(CreateOptionTile.columns(for: .xLarge), 2)
        XCTAssertEqual(CreateOptionTile.columns(for: .xxLarge), 1)
        XCTAssertEqual(CreateOptionTile.columns(for: .accessibility5), 1)
        XCTAssertEqual(CreateInputKind.speak.subtitle, "Record your voice", "F20: one word per action")
        XCTAssertEqual(CreateChoices.OutputKind.voiceMessage.subtitle, "An audio file you can send")
    }

    func testImportSendsEachFileToItsReader() {
        let urls = ["a.m4a", "b.pdf", "c.mov", "d.docx", "e.txt"].map {
            URL(fileURLWithPath: "/tmp/synthetic-\($0)")
        }
        let split = CaptureScreen.splitImports(urls)
        XCTAssertEqual(split.media.map(\.lastPathComponent), ["synthetic-a.m4a", "synthetic-c.mov"])
        XCTAssertEqual(
            split.documents.map(\.lastPathComponent), ["synthetic-b.pdf", "synthetic-d.docx", "synthetic-e.txt"])
    }

    // MARK: - Versions say what changed (F30)

    func testVersionsSayWhatChangedInLines() {
        XCTAssertNil(DocumentVersionsSheet.changeSummary("One", previous: nil), "the first version")
        XCTAssertEqual(DocumentVersionsSheet.changeSummary("A\nB", previous: "A\nB"), "No text changes")
        XCTAssertEqual(DocumentVersionsSheet.changeSummary("A\nX", previous: "A\nB"), "1 line changed")
        XCTAssertEqual(DocumentVersionsSheet.changeSummary("A\nB\nC", previous: "A"), "2 lines added")
        XCTAssertEqual(DocumentVersionsSheet.changeSummary("A", previous: "A\nB\nC\nD"), "3 lines removed")
        XCTAssertEqual(DocumentVersionsSheet.changeSummary("X\nY\nZ", previous: "A\nB"), "2 lines changed, 1 added")
    }

    // MARK: - Voice messages and the voice questions

    func testAVoiceMessageBeingMadeCannotBeSwipedAway() {
        XCTAssertTrue(VoiceMessageSheet.isMaking(.preparing))
        XCTAssertTrue(VoiceMessageSheet.isMaking(.synthesizing(done: 1, total: 3)))
        XCTAssertTrue(VoiceMessageSheet.isMaking(.assembling))
        XCTAssertFalse(VoiceMessageSheet.isMaking(.idle))
        XCTAssertFalse(VoiceMessageSheet.isMaking(.failed("Synthetic failure.")))
    }

    func testTheVoiceQuestionPutsTheReasonFirst() {
        XCTAssertEqual(
            VoiceQuestionReason.message("It will leave this iPhone.", reason: nil), "It will leave this iPhone.")
        XCTAssertEqual(
            VoiceQuestionReason.message("It will leave this iPhone.", reason: "Marked Personal, but it counts."),
            "Marked Personal, but it counts. It will leave this iPhone.")
    }

    func testTheClinicalChoicesLookRisky() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let files = [
            "App/Sources/Screens/Transforms/ClinicalConfirmation.swift": #"Button("Send", role: .destructive)"#,
            "App/Sources/Screens/Create/VoiceMessageViews.swift": #"Button("Send", role: .destructive)"#,
            "App/Sources/Screens/Shared/VoiceViews.swift": #"Button("Read aloud", role: .destructive)"#,
        ]
        for (path, button) in files {
            let source = try String(contentsOf: repo.appendingPathComponent(path), encoding: .utf8)
            XCTAssertTrue(source.contains(button), "F46: \(path)")
        }
    }
}
