import ChirpCore
import SwiftUI
import UIKit
import XCTest

@testable import iChirp

/// Plan 024 Task 9, fix round 1 (R6a-12): the app has no Dynamic Type cap, so Capture, the Library, a completed
/// transcript (with its player) and a document are drawn at AX5 (and at the default size, for comparison) in a real
/// window (`drawHierarchy` draws ScrollViews and Lists, which `ImageRenderer` does not), each in a navigation stack as
/// the app shows them. Each must lay out at the phone's width. The transcript and the document come from the Library this
/// test host holds; with none, that render is skipped (the shell tour, `UITests/ShellScreensTourUITests.swift`, takes
/// the same screens on a populated simulator). With `CHIRP_RENDER_DIR` set the images are written there. Nothing here
/// writes to the store.
@MainActor
final class ShellScreensRenderTests: XCTestCase {
    private static let size = CGSize(width: 402, height: 874)  // iPhone 17 Pro

    private func environment() async throws -> AppEnvironment {
        guard case .ready(let environment) = AppEnvironment.shared else {
            throw XCTSkip("The app environment did not start in this test host.")
        }
        await environment.launch()
        return environment
    }

    func testCaptureAndLibraryLayOutAtAX5() async throws {
        let environment = try await environment()
        for (typeSize, suffix) in [(DynamicTypeSize.large, "default"), (.accessibility5, "ax5")] {
            try await render(
                CaptureScreen(openTab: { _ in }).environment(environment), typeSize: typeSize,
                name: "render-capture-\(suffix)")
            try await render(
                LibraryScreen().environment(environment), typeSize: typeSize, name: "render-library-\(suffix)")
        }
    }

    func testATranscriptWithItsPlayerAndADocumentLayOutAtAX5() async throws {
        let environment = try await environment()
        let items = environment.library.items
        let transcript = items.first { $0.status == .completed && !$0.isTextOnly && $0.mediaRelativePath != nil }
        let document = items.first { $0.status == .completed && $0.isTextOnly }
        guard transcript != nil || document != nil else {
            throw XCTSkip("This test host's Library has no completed transcript or document to draw.")
        }
        for (typeSize, suffix) in [(DynamicTypeSize.large, "default"), (.accessibility5, "ax5")] {
            if let transcript {
                try await render(
                    NavigationStack { TranscriptScreen(id: transcript.id) }.environment(environment),
                    typeSize: typeSize, name: "render-transcript-\(suffix)")
            }
            if let document {
                try await render(
                    NavigationStack { DocumentScreen(id: document.id) }.environment(environment),
                    typeSize: typeSize, name: "render-document-\(suffix)")
            }
        }
    }

    /// Shows `view` as a window's root at `typeSize`, waits for it to load, then draws the window.
    private func render(_ view: some View, typeSize: DynamicTypeSize, name: String) async throws {
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first, "no window scene")
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: Self.size)
        window.rootViewController = UIHostingController(
            rootView: view.environment(\.dynamicTypeSize, typeSize).tint(AppColor.accentText))
        window.isHidden = false
        defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(1500))  // the screen's own load (a store read) has no signal to await
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        XCTAssertEqual(image.size.width, Self.size.width, accuracy: 1, name)
        if let directory = ProcessInfo.processInfo.environment["CHIRP_RENDER_DIR"], !directory.isEmpty {
            let url = URL(fileURLWithPath: directory).appendingPathComponent("\(name).png")
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try XCTUnwrap(image.pngData()).write(to: url)
        }
    }
}
