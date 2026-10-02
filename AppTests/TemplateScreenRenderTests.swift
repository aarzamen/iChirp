import ChirpCore
import ChirpFeatures
import ChirpUI
import SwiftUI
import XCTest

@testable import iChirp

/// Plan 026's images of the template screens (Templates, the editor, the instructions sheet, the Transforms tab's
/// templates, a document's Details, Settings → Text), in light, dark and AX3. A review tool, not an assertion test: it
/// runs only with `CHIRP_RENDER_DIR` set (`TEST_RUNNER_CHIRP_RENDER_DIR=<dir>` through xcodebuild) and writes there.
/// It seeds synthetic rows into the test host's own database (run it on a simulator of your own), shows each screen
/// in a window, gives its `.task` loads a moment, then draws the window (the method of `Task10ScreenRenderTests`).
@MainActor
final class TemplateScreenRenderTests: XCTestCase {
    private static let size = CGSize(width: 402, height: 1500)

    func testRenderTemplateScreens() async throws {
        guard let directory = ProcessInfo.processInfo.environment["CHIRP_RENDER_DIR"], !directory.isEmpty else {
            throw XCTSkip("Set CHIRP_RENDER_DIR to write the template screen images.")
        }
        guard case .ready(let environment) = AppEnvironment.shared else {
            throw XCTSkip("The app environment did not start in this test host.")
        }
        let output = URL(fileURLWithPath: directory)
        try await environment.deliverables.installBuiltInTemplates()

        // Before any template of your own: the empty-state card.
        await renderAll("templates-empty", AnyView(NavigationStack { TemplatesScreen() }), environment, output)

        let seeded = try await seed(environment)
        let fetchedSOAP = try await environment.deliverableStore.fetchTemplate(id: seeded.soap)
        let soap = try XCTUnwrap(fetchedSOAP)
        let fromSOAP = environment.makeTemplateEditor(.new(startingFrom: soap))
        await fromSOAP.load()
        let duplicate = environment.makeTemplateEditor(.new(startingFrom: nil))
        await duplicate.load()
        duplicate.name = "soap note"
        duplicate.instructions = "Use the headings Visit, Findings, Plan."
        let editing = environment.makeTemplateEditor(.edit(seeded.clinic))
        await editing.load()
        editing.instructions += "\nAdd a Follow-up heading."

        let screens: [(String, AnyView)] = [
            ("templates", AnyView(NavigationStack { TemplatesScreen() })),
            ("transforms", AnyView(TransformsScreen())),
            ("editor-from-soap", AnyView(TemplateEditorSheet(model: fromSOAP, onTry: { _ in }))),
            ("editor-duplicate-name", AnyView(TemplateEditorSheet(model: duplicate, onTry: { _ in }))),
            ("editor-edit", AnyView(TemplateEditorSheet(model: editing, onTry: { _ in }))),
            (
                "instructions",
                AnyView(
                    TemplateInstructionsSheet(
                        subtitle: "Clinic SOAP · version 1",
                        text: "Use the headings Visit, Findings, Plan.\nKeep every dose exactly as said."))
            ),
            (
                "document-details",
                AnyView(
                    NavigationStack {
                        DeliverableDetailScreen(id: seeded.document, environment: environment, showsDetails: true)
                    })
            ),
            ("settings", AnyView(NavigationStack { SettingsScreen() })),
        ]
        for (name, view) in screens {
            await renderAll(name, view, environment, output)
        }
    }

    private func renderAll(_ name: String, _ view: AnyView, _ environment: AppEnvironment, _ output: URL) async {
        let variants: [(String, UIUserInterfaceStyle, DynamicTypeSize)] = [
            ("light", .light, .large), ("dark", .dark, .large), ("ax3", .light, .accessibility3),
        ]
        for (suffix, style, typeSize) in variants {
            do {
                try await render(
                    view.environment(environment).environment(\.dynamicTypeSize, typeSize), style: style,
                    to: output.appendingPathComponent("\(name)-\(suffix).png"))
            } catch {
                XCTFail("\(name)-\(suffix): \(error)")
            }
        }
    }

    private struct Seeded {
        let soap: UUID
        let clinic: PromptTemplate
        let document: UUID
    }

    /// A synthetic personal transcript; "Clinic SOAP" (from SOAP note) made a document at version 1, then was edited
    /// to version 2 and renamed; Agenda is hidden; "Old letter" is deleted. Made once per test host.
    private func seed(_ environment: AppEnvironment) async throws -> Seeded {
        let store = environment.deliverableStore
        let templates = try await store.fetchTemplates()
        let soap = try XCTUnwrap(templates.first { $0.canonicalKey == "soap-note" })
        let agenda = try XCTUnwrap(templates.first { $0.canonicalKey == "agenda" })
        var row = Transcription(
            fileName: "synthetic-visit.m4a", durationMs: 95_000, status: .completed, privacyClass: .personal)
        row.titleOverride = "Synthetic clinic visit"
        row.rawTranscript = "The follow-up moves to Thursday. Take 2.5 mg twice a day."
        try await environment.store.insert(row)

        let clinic = try await store.createUserTemplate(
            TemplateDraft(
                name: "Clinic SOAP", category: .deliverable,
                instructions: "Use the headings Visit, Findings, Plan.\nKeep every dose exactly as said.",
                makesClinicalDocuments: true))
        let document = Deliverable(
            transcriptionID: row.id, promptID: clinic.id, promptVersionID: clinic.activeVersionID,
            title: "Clinic SOAP", engineID: "apple.foundation-models", provider: "Apple on-device model", model: nil,
            locality: .onDevice, text: "## Visit\nSynthetic follow-up.\n\n## Plan\n- Thursday", privacyClass: .clinical)
        try await store.insertDeliverable(document)
        let edited = try await store.updateUserTemplate(
            id: clinic.id,
            with: TemplateDraft(
                name: "SOAP (clinic)", category: .deliverable,
                instructions: "Use the headings Visit, Findings, Assessment, Plan.\nKeep every dose exactly as said.",
                makesClinicalDocuments: true))
        _ = try await store.createUserTemplate(
            TemplateDraft(
                name: "Plain words", category: .transform, instructions: "Rewrite in plain words for a patient.",
                makesClinicalDocuments: false))
        let old = try await store.createUserTemplate(
            TemplateDraft(
                name: "Old letter", category: .deliverable, instructions: "Write a short letter.",
                makesClinicalDocuments: false))
        try await store.deleteUserTemplate(id: old.id)
        try await store.setTemplateVisible(id: agenda.id, isVisible: false)
        await environment.library.start()
        await environment.deliverableLibrary.load()
        await environment.templateLibrary.load()
        return Seeded(soap: soap.id, clinic: edited, document: document.id)
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
        // The screen's own `.task` loads finish in this moment. A review tool's settle time, not a test's wait.
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
