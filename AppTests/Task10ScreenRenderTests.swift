import ChirpCore
import ChirpFeatures
import ChirpUI
import SwiftUI
import XCTest

@testable import iChirp

/// Plan 024 Task 10's before/after images of the screens it changed (Create, Transforms, the document screen, Ask,
/// Edit by voice, Settings and its sub-screens), in light, dark and AX3. A review tool, not an assertion test: it runs
/// only with `CHIRP_RENDER_DIR` set (`TEST_RUNNER_CHIRP_RENDER_DIR=<dir>` through xcodebuild) and writes there. It
/// seeds synthetic rows into the test host's own database (its simulator is the lane's own), shows each screen in a
/// window, gives its `.task` loads a moment, then draws the window with `drawHierarchy` (which, unlike `ImageRenderer`,
/// draws text fields, menus and scroll views).
@MainActor
final class Task10ScreenRenderTests: XCTestCase {
    private static let size = CGSize(width: 402, height: 1300)

    func testRenderTask10Screens() async throws {
        guard let directory = ProcessInfo.processInfo.environment["CHIRP_RENDER_DIR"], !directory.isEmpty else {
            throw XCTSkip("Set CHIRP_RENDER_DIR to write the Task 10 screen images.")
        }
        guard case .ready(let environment) = AppEnvironment.shared else {
            throw XCTSkip("The app environment did not start in this test host.")
        }
        let seeded = try await seed(environment)
        let screens: [(String, AnyView)] = [
            ("transforms", AnyView(TransformsScreen())),
            (
                "document",
                AnyView(NavigationStack { DeliverableDetailScreen(id: seeded.document, environment: environment) })
            ),
            (
                "transform-sheet",
                AnyView(
                    TransformSheet(
                        transcriptionID: seeded.transcript, transcriptTitle: "Synthetic clinic visit",
                        privacyClass: .personal, environment: environment))
            ),
            (
                "ask",
                AnyView(
                    AskView(
                        transcription: seeded.transcription,
                        session: AskSessionViewModel(
                            service: environment.deliverables, transcriptionID: seeded.transcript),
                        environment: environment, seek: { _ in }))
            ),
            ("create", AnyView(CreateSheet(host: CreateHost(), environment: environment))),
            (
                "edit-by-voice",
                AnyView(
                    EditByVoiceSheet(
                        document: environment.makeDocumentViewModel(id: seeded.document), environment: environment,
                        onSaved: {}))
            ),
            ("settings", AnyView(NavigationStack { SettingsScreen() })),
            ("text-rules", AnyView(NavigationStack { TextRulesScreen(model: environment.textRules) })),
            ("speech-engines", AnyView(NavigationStack { SpeechEnginesScreen() })),
            ("voices", AnyView(NavigationStack { VoicesSettingsScreen() })),
            ("models", AnyView(NavigationStack { ModelsSettingsScreen() })),
            ("structure-gate", AnyView(NavigationStack { StructureGateScreen() })),
        ]
        let variants: [(String, UIUserInterfaceStyle, DynamicTypeSize)] = [
            ("light", .light, .large), ("dark", .dark, .large), ("ax3", .light, .accessibility3),
        ]
        for (name, view) in screens {
            for (suffix, style, typeSize) in variants {
                try await render(
                    view.environment(environment).environment(\.dynamicTypeSize, typeSize), style: style,
                    to: URL(fileURLWithPath: directory).appendingPathComponent("\(name)-\(suffix).png"))
            }
        }
    }

    private struct Seeded {
        let transcript: UUID
        let transcription: Transcription
        let document: UUID
    }

    /// One synthetic timed transcript marked Personal, a clinical SOAP note made from it (so the transcript counts as
    /// clinical), and a Summary of it that the model cut off. Made once per test host.
    private func seed(_ environment: AppEnvironment) async throws -> Seeded {
        try await environment.deliverables.installBuiltInTemplates()
        let templates = try await environment.deliverableStore.fetchTemplates()
        let summary = templates.first { $0.canonicalKey == "summary" }
        let soap = templates.first { $0.canonicalKey == "soap-note" }
        var row = Transcription(
            fileName: "synthetic-visit.m4a", durationMs: 95_000, status: .completed, privacyClass: .personal)
        row.titleOverride = "Synthetic clinic visit"
        row.rawTranscript = "The follow-up moves to Thursday. Take 2.5 mg twice a day."
        row.wordTimestamps = [
            WordTimestamp(word: "The", startMs: 0, endMs: 200, confidence: 1),
            WordTimestamp(word: "follow-up", startMs: 200, endMs: 700, confidence: 1),
            WordTimestamp(word: "moves", startMs: 700, endMs: 1000, confidence: 1),
            WordTimestamp(word: "to", startMs: 1000, endMs: 1100, confidence: 1),
            WordTimestamp(word: "Thursday.", startMs: 1100, endMs: 1600, confidence: 1),
        ]
        try await environment.store.insert(row)
        let note = Deliverable(
            transcriptionID: row.id, promptID: soap?.id, promptVersionID: soap?.activeVersionID, title: "SOAP note",
            engineID: "apple.foundation-models", provider: "Apple on-device model", model: nil, locality: .onDevice,
            text: "## Subjective\nSynthetic follow-up.\n\n## Plan\n- Thursday", privacyClass: .clinical)
        try await environment.deliverableStore.insertDeliverable(note)
        let cutOff = Deliverable(
            transcriptionID: row.id, promptID: summary?.id, promptVersionID: summary?.activeVersionID,
            title: "Summary", engineID: "apple.foundation-models", provider: "Apple on-device model", model: nil,
            locality: .onDevice,
            text: "## Key points\n- The follow-up moves to Thursday.\n- The dose is 2.5 mg twice a day.\n- The",
            privacyClass: .personal, isCutOff: true)
        try await environment.deliverableStore.insertDeliverable(cutOff)
        await environment.library.start()
        await environment.deliverableLibrary.load()
        return Seeded(transcript: row.id, transcription: row, document: cutOff.id)
    }

    private func render(_ view: some View, style: UIUserInterfaceStyle, to url: URL) async throws {
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first, "no window scene")
        let host = UIHostingController(rootView: view.background(Tokens.Color.ground))
        host.overrideUserInterfaceStyle = style
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: Self.size)
        window.overrideUserInterfaceStyle = style
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true }
        // The screen's own `.task` loads (the document, the effective class, the models) finish in this moment. A
        // review tool's settle time, not a test's wait.
        try await Task.sleep(for: .milliseconds(900))
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try XCTUnwrap(image.pngData()).write(to: url)
    }
}
