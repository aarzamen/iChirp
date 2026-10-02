import SwiftUI
import XCTest

@testable import iChirp

/// Polish lane u3: the Dictating screen cannot be run in the simulator (no microphone path may start there), so this
/// renders its idle state off screen at the default size and at AX2, AX3 and AX5 (the app has no Dynamic Type cap since plan 024, R6a-12), and checks that
/// it lays out. (The Meeting screen is a ScrollView, which `ImageRenderer` does not draw, so it is not rendered here.) With `CHIRP_RENDER_DIR` set (`TEST_RUNNER_CHIRP_RENDER_DIR=<dir>` through
/// xcodebuild) the images are written there for review. Nothing here records or starts a session.
@MainActor
final class DictatingScreenRenderTests: XCTestCase {
    private static let size = CGSize(width: 402, height: 874)  // iPhone 17 Pro

    private func environment() throws -> AppEnvironment {
        guard case .ready(let environment) = AppEnvironment.shared else {
            throw XCTSkip("The app environment did not start in this test host.")
        }
        XCTAssertEqual(environment.dictation.state, .idle, "the render must not follow a real dictation")
        return environment
    }

    private func render(_ view: some View, name: String, dynamicTypeSize: DynamicTypeSize) throws {
        let sized = view.environment(\.dynamicTypeSize, dynamicTypeSize)
            .frame(width: Self.size.width, height: Self.size.height)
        let renderer = ImageRenderer(content: sized)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.uiImage, "\(name) did not render")
        XCTAssertEqual(image.size.width, Self.size.width, accuracy: 1)
        if let directory = ProcessInfo.processInfo.environment["CHIRP_RENDER_DIR"], !directory.isEmpty {
            let url = URL(fileURLWithPath: directory).appendingPathComponent("\(name).png")
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try XCTUnwrap(image.pngData()).write(to: url)
        }
    }

    func testDictatingScreenRendersAtDefaultAndAccessibilitySizes() throws {
        let environment = try environment()
        for (size, suffix) in [
            (DynamicTypeSize.large, "default"), (.accessibility2, "ax2"), (.accessibility3, "ax3"),
            (.accessibility5, "ax5"),
        ] {
            try render(
                DictatingScreen(openTab: { _ in }).environment(environment),
                name: "render-dictating-idle-\(suffix)", dynamicTypeSize: size)
        }
        XCTAssertEqual(environment.dictation.state, .idle, "rendering starts nothing")
    }
}
