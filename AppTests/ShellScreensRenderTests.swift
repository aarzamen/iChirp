import ChirpCore
import SwiftUI
import UIKit
import XCTest

@testable import iChirp

/// Plan 024 Task 9 (R6a-12): an opt-in **render capture**, not a layout test. With no app-wide Dynamic Type cap,
/// Capture, the Library, a completed transcript (with its player) and a document are drawn at the default size and at
/// AX5 in a real window (`drawHierarchy` draws ScrollViews and Lists, which `ImageRenderer` does not), each in a
/// navigation stack as the app shows them, so a person can look at them. It runs only with `CHIRP_RENDER_DIR` set
/// (`TEST_RUNNER_CHIRP_RENDER_DIR=<dir>` through xcodebuild) and is skipped otherwise; the images are written there.
///
/// It checks nothing about the layout itself: a SwiftUI page's overflow does not show in its UIKit scroll view's size
/// (a deliberately too-wide line passed such a check), so the evidence is the images, looked at, and the shell tour
/// (`UITests/ShellScreensTourUITests.swift`) on a populated simulator. The transcript and the document come from the
/// Library this test host holds; with none, they are not drawn. Nothing here writes to the store.
@MainActor
final class ShellScreensRenderTests: XCTestCase {
    private static let size = CGSize(width: 402, height: 874)  // iPhone 17 Pro

    private func renderDirectory() throws -> URL {
        guard let path = ProcessInfo.processInfo.environment["CHIRP_RENDER_DIR"], !path.isEmpty else {
            throw XCTSkip("Render capture only: set TEST_RUNNER_CHIRP_RENDER_DIR to draw the screens.")
        }
        return URL(fileURLWithPath: path)
    }

    private func environment() async throws -> AppEnvironment {
        guard case .ready(let environment) = AppEnvironment.shared else {
            throw XCTSkip("The app environment did not start in this test host.")
        }
        await environment.launch()
        return environment
    }

    func testCaptureCaptureAndLibraryAtAX5() async throws {
        let directory = try renderDirectory()
        let environment = try await environment()
        for (typeSize, suffix) in [(DynamicTypeSize.large, "default"), (.accessibility5, "ax5")] {
            try await capture(
                CaptureScreen(openTab: { _ in }).environment(environment), typeSize: typeSize,
                to: directory.appendingPathComponent("render-capture-\(suffix).png"))
            try await capture(
                LibraryScreen().environment(environment), typeSize: typeSize,
                to: directory.appendingPathComponent("render-library-\(suffix).png"))
        }
    }

    func testCaptureATranscriptWithItsPlayerAndADocumentAtAX5() async throws {
        let directory = try renderDirectory()
        let environment = try await environment()
        let items = environment.library.items
        let transcript = items.first { $0.status == .completed && !$0.isTextOnly && $0.mediaRelativePath != nil }
        let document = items.first { $0.status == .completed && $0.isTextOnly }
        guard transcript != nil || document != nil else {
            throw XCTSkip("This test host's Library has no completed transcript or document to draw.")
        }
        for (typeSize, suffix) in [(DynamicTypeSize.large, "default"), (.accessibility5, "ax5")] {
            if let transcript {
                try await capture(
                    NavigationStack { TranscriptScreen(id: transcript.id) }.environment(environment),
                    typeSize: typeSize, to: directory.appendingPathComponent("render-transcript-\(suffix).png"))
            }
            if let document {
                try await capture(
                    NavigationStack { DocumentScreen(id: document.id) }.environment(environment),
                    typeSize: typeSize, to: directory.appendingPathComponent("render-document-\(suffix).png"))
            }
        }
    }

    /// Shows `view` as a window's root at `typeSize` and writes the window's image to `url` once two draws in a row are
    /// the same (the screen has loaded its row and settled), or after five seconds.
    private func capture(_ view: some View, typeSize: DynamicTypeSize, to url: URL) async throws {
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first, "no window scene")
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: Self.size)
        window.rootViewController = UIHostingController(
            rootView: view.environment(\.dynamicTypeSize, typeSize).tint(AppColor.accentText))
        window.isHidden = false
        defer { window.isHidden = true }

        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        func draw() -> Data? {
            UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
                _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }.pngData()
        }
        let deadline = Date().addingTimeInterval(5)
        var previous: Data?
        var current = draw()
        while current != previous, Date() < deadline {
            try await Task.sleep(for: .milliseconds(200))
            previous = current
            current = draw()
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try XCTUnwrap(current).write(to: url)
    }
}
