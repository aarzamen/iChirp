import ChirpCore
import ChirpFeatures
import SwiftUI
import UIKit
import XCTest

@testable import iChirp

/// Plan 024 Task 9: the shell, Capture, Library, Transcript and Document screens' logic (review R6a).
@MainActor
final class ShellScreensTests: XCTestCase {
    // MARK: - R6a-2: Capture's meeting row says "Recording" only while recording

    private static let everyMeetingState: [MeetingFlowState] = [
        .idle, .starting, .recording, .paused, .interrupted, .waitingForResume, .stopping, .saved(UUID()),
        .failed(message: "Synthetic failure", transcriptionID: UUID()),
        .failed(message: "No start", transcriptionID: nil),
    ]

    func testMeetingRowNeverSaysRecordingUnlessItRecords() {
        for state in Self.everyMeetingState {
            let words = [
                MeetingRowCopy.title(for: state),
                MeetingRowCopy.subtitle(for: state, seconds: 724, finalPassProgress: 0.62),
                MeetingRowCopy.hint(for: state),
            ].joined(separator: " | ")
            if state == .recording {
                XCTAssertTrue(words.contains("Recording · 12:04"), words)
            } else {
                XCTAssertFalse(words.contains("Recording ·"), "\(state): \(words)")
                XCTAssertFalse(words.localizedCaseInsensitiveContains("is recording"), "\(state): \(words)")
            }
        }
    }

    func testMeetingRowNamesEachNonRecordingState() {
        XCTAssertEqual(
            MeetingRowCopy.subtitle(for: .paused, seconds: 724, finalPassProgress: nil),
            "Paused · 12:04 · nothing is recorded")
        XCTAssertTrue(
            MeetingRowCopy.subtitle(for: .interrupted, seconds: 724, finalPassProgress: nil).hasPrefix(
                "Interrupted · 12:04"))
        XCTAssertTrue(
            MeetingRowCopy.subtitle(for: .waitingForResume, seconds: 724, finalPassProgress: nil).contains("Resume"))
        XCTAssertEqual(
            MeetingRowCopy.subtitle(for: .stopping, seconds: 724, finalPassProgress: 0.62), "Transcribing · 62%")
        XCTAssertEqual(
            MeetingRowCopy.subtitle(for: .stopping, seconds: 724, finalPassProgress: nil), "Transcribing on this iPhone"
        )
        XCTAssertEqual(MeetingRowCopy.button(for: .idle), "Start")
        XCTAssertEqual(MeetingRowCopy.button(for: .waitingForResume), "Return")
        XCTAssertEqual(MeetingRowCopy.title(for: .failed(message: "x", transcriptionID: UUID())), "Record Meeting")
    }

    func testTheMeetingScreenShowsUnlessHiddenOrADictationHasTheScreen() {
        XCTAssertTrue(MeetingCoverLayer.isShown(state: .paused, isScreenHidden: false, dictationState: .idle))
        XCTAssertFalse(MeetingCoverLayer.isShown(state: .paused, isScreenHidden: true, dictationState: .idle))
        XCTAssertFalse(MeetingCoverLayer.isShown(state: .recording, isScreenHidden: false, dictationState: .starting))
        XCTAssertFalse(MeetingCoverLayer.isShown(state: .idle, isScreenHidden: false, dictationState: .idle))
    }

    // MARK: - R6a-3: a Retry that reports no job progress still reloads the screen

    func testReloadKeyChangesWhenOnlyTheStoredStatusChanges() {
        let failed = ItemReloadKey(stage: nil, status: .failed)
        XCTAssertNotEqual(failed, ItemReloadKey(stage: nil, status: .processing))
        XCTAssertNotEqual(ItemReloadKey(stage: nil, status: .processing), ItemReloadKey(stage: nil, status: .completed))
    }

    // MARK: - R6a-4: the overlay windows

    func testTheTopPresentingLayerWins() {
        XCTAssertNil(RootOverlayWindows.topLayer(of: []))
        XCTAssertEqual(RootOverlayWindows.topLayer(of: [.meeting, .dictating]), .dictating)
        XCTAssertEqual(RootOverlayWindows.topLayer(of: [.meeting, .trackChoice]), .trackChoice)
        XCTAssertTrue(RootOverlayLayer.showsDictating(.starting))
        XCTAssertFalse(RootOverlayLayer.showsDictating(.idle))
        XCTAssertFalse(RootOverlayLayer.showsDictating(.cancelled))
    }

    func testAnOverlayWindowLetsTouchesThroughWhereItPresentsNothing() throws {
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first, "a window scene")
        let window = PassthroughWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 400, height: 800)
        let host = UIHostingController(rootView: Color.clear)
        host.view.backgroundColor = .clear
        host.view.isUserInteractionEnabled = false
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true }
        window.layoutIfNeeded()
        XCTAssertNil(window.hitTest(CGPoint(x: 200, y: 400), with: nil), "an empty overlay takes no touch")
        let presented = UIView(frame: window.bounds)
        window.addSubview(presented)
        XCTAssertTrue(window.hitTest(CGPoint(x: 200, y: 400), with: nil) === presented, "a presented screen does")
    }

    // MARK: - R6a-5: routes carry the kind; view models are made once

    func testRoutesCarryTheKindOfTheRowThatWasTapped() {
        let text = TranscriptionSummary(Transcription(sourceType: .text, fileName: "Typed text", status: .completed))
        let document = TranscriptionSummary(Transcription(sourceType: .document, fileName: "a.pdf", status: .completed))
        let dictation = TranscriptionSummary(
            Transcription(sourceType: .dictation, fileName: "d.wav", status: .completed))
        let meeting = TranscriptionSummary(Transcription(sourceType: .meeting, fileName: "m.caf", status: .failed))
        XCTAssertEqual(LibraryRoute.item(text), .item(text.id, isTextOnly: true))
        XCTAssertEqual(LibraryRoute.item(document), .item(document.id, isTextOnly: true))
        XCTAssertEqual(LibraryRoute.item(dictation), .item(dictation.id, isTextOnly: false))
        XCTAssertEqual(LibraryRoute.item(meeting), .item(meeting.id, isTextOnly: false))
        // An id from a sheet: the listed row's kind, else the caller's fallback.
        let unknown = UUID()
        XCTAssertEqual(LibraryRoute.item(id: text.id, in: [text]), .item(text.id, isTextOnly: true))
        XCTAssertEqual(LibraryRoute.item(id: unknown, in: [text]), .item(unknown, isTextOnly: false))
        XCTAssertEqual(
            LibraryRoute.item(id: unknown, in: [], fallbackIsTextOnly: true), .item(unknown, isTextOnly: true))
        XCTAssertEqual(LibraryRoute.item(text).itemID, text.id)
        XCTAssertNil(LibraryRoute.document(UUID()).itemID)
    }

    func testAScreenMakesItsObjectsOnceAcrossParentUpdates() {
        let tick = OnceBoxTick()
        let host = UIHostingController(rootView: OnceBoxParent(tick: tick))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 200))
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true }
        for value in 1...5 {
            tick.value = value
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertGreaterThanOrEqual(tick.childRenders, 2, "the child re-rendered with its parent")
        XCTAssertEqual(tick.makes, 1, "the objects were made once, not on every parent update")
    }

    // MARK: - R6a-7: one row, one hint per kind

    func testRowHintsNameWhatEachKindOpens() {
        XCTAssertEqual(LibraryItemRow.rowHint(for: .text), "Opens this text")
        XCTAssertEqual(LibraryItemRow.rowHint(for: .document), "Opens this document")
        for kind: Transcription.SourceType in [.file, .meeting, .dictation, .url, .podcast] {
            XCTAssertEqual(LibraryItemRow.rowHint(for: kind), "Opens the transcript", "\(kind)")
        }
    }

    // MARK: - R6a-14: See all shows everything

    func testSeeAllClearsTheLibraryFilterAndSearch() throws {
        guard case .ready(let environment) = AppEnvironment.shared else {
            throw XCTSkip("The app environment did not start in this test host.")
        }
        let library = environment.library
        let (filter, search) = (library.filter, library.searchText)
        defer {
            library.filter = filter
            library.searchText = search
        }
        library.filter = .documents
        library.searchText = "synthetic"
        LibraryNavigation.showEverything(library)
        XCTAssertEqual(library.filter, .all)
        XCTAssertEqual(library.searchText, "")
    }

    // MARK: - R6a-15: the shell screens read radii, fonts and inks from Tokens

    func testShellScreensUseTokensNotLiterals() throws {
        let screens = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("App/Sources/Screens")
        // Task 9's screens (Task 10's run the same rules on theirs when they adopt ChirpUI).
        let folders = ["Capture", "Dictating", "Meeting", "Library", "Transcript", "Documents", "Shared"]
        let rules: [(pattern: String, why: String, except: Set<String>)] = [
            (#"cornerRadius: [0-9]"#, "a literal radius (use Tokens.Radius)", ["DictatingScreen.swift"]),
            (#"design: \.rounded"#, "a rounded-font call (use Tokens.Font.rounded or chirpTitleFont)", []),
            (#"foregroundStyle\(\.white\)"#, "a white label (use Tokens.Color.onAccent)", ["DictatingScreen.swift"]),
            (#"CapsuleButtonLabel\("#, "a hand-rolled pill (use ChirpButtonStyle)", []),
            (#"[^p]CardBackground\("#, "the old card (use ChirpCardBackground)", []),
        ]
        var problems: [String] = []
        var scanned = 0
        for folder in folders {
            let root = screens.appendingPathComponent(folder)
            let files = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
            for case let file as URL in files where file.pathExtension == "swift" {
                // WhereThingsRunSheet is Task 10's carried fix (its tint button), left to that lane.
                guard file.lastPathComponent != "WhereThingsRunSheet.swift" else { continue }
                scanned += 1
                let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
                for (number, line) in lines.enumerated() {
                    let code = line.range(of: "//").map { String(line[..<$0.lowerBound]) } ?? line
                    for rule in rules where !rule.except.contains(file.lastPathComponent) {
                        if code.range(of: rule.pattern, options: .regularExpression) != nil {
                            problems.append("\(file.lastPathComponent):\(number + 1): \(rule.why)")
                        }
                    }
                }
            }
        }
        XCTAssertGreaterThan(scanned, 20, "the scan found the screens")
        XCTAssertEqual(problems, [])
    }

    // MARK: - R6a-16: words that match the item

    func testItemNounsAndRenameWords() {
        let text = Transcription(sourceType: .text, fileName: "Typed text", status: .completed)
        let document = Transcription(sourceType: .document, fileName: "a.pdf", status: .completed)
        let recording = Transcription(sourceType: .dictation, fileName: "d.wav", status: .completed)
        XCTAssertEqual(ItemNoun.renameTitle(for: text), "Rename text")
        XCTAssertEqual(ItemNoun.renameTitle(for: document), "Rename document")
        XCTAssertEqual(ItemNoun.renameTitle(for: recording), "Rename transcript")
        XCTAssertEqual(ItemNoun.renameHint(for: text), "Renames the text")
        XCTAssertTrue(ItemNoun.renameMessage(for: document).contains("document’s own title"))
    }
}

/// Drives `OnceBoxParent` re-renders and counts what its child made.
@MainActor @Observable final class OnceBoxTick {
    var value = 0
    @ObservationIgnored var makes = 0
    @ObservationIgnored var childRenders = 0
}

private struct OnceBoxParent: View {
    let tick: OnceBoxTick

    var body: some View {
        OnceBoxChild(value: tick.value, tick: tick)
    }
}

/// Built anew by every parent render (its `value` changes), like a pushed screen inside a re-rendering stack.
private struct OnceBoxChild: View {
    let value: Int
    let tick: OnceBoxTick
    @State private var box = OnceBox<NSObject>()

    var body: some View {
        let object = box.get {
            tick.makes += 1
            return NSObject()
        }
        let _ = (tick.childRenders += 1)
        Text("\(value) \(ObjectIdentifier(object).hashValue)")
    }
}
