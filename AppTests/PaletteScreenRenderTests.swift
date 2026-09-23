import SwiftUI
import UIKit
import XCTest

@testable import iChirp

/// Plan 023 (F6, the dark palette): the Dictating and Meeting screens cannot be opened in the simulator (no microphone
/// path may start there), so this renders both in their idle state, each presented as a real full-screen cover over a
/// Light-mode and a Dark-mode window, at the default text size and at AX2 (the app's largest). That checks that the
/// Dictating screen, dark by design, looks the same whatever the system scheme, and gives the owner light and dark
/// images of both. A window is drawn with `drawHierarchy`, which (unlike `ImageRenderer`) draws the Meeting screen's
/// ScrollView. Nothing records: both screens read the idle coordinators and start nothing on appear. With
/// `CHIRP_RENDER_DIR` set (`TEST_RUNNER_CHIRP_RENDER_DIR=<dir>` through xcodebuild) the images are written there.
@MainActor
final class PaletteScreenRenderTests: XCTestCase {
    private static let size = CGSize(width: 402, height: 874)  // iPhone 17 Pro

    private func environment() throws -> AppEnvironment {
        guard case .ready(let environment) = AppEnvironment.shared else {
            throw XCTSkip("The app environment did not start in this test host.")
        }
        XCTAssertEqual(environment.dictation.state, .idle, "the render must not follow a real dictation")
        XCTAssertEqual(environment.meeting.state, .idle, "the render must not follow a real meeting")
        return environment
    }

    func testDictatingAndMeetingRenderInLightAndDarkWindows() async throws {
        let environment = try environment()
        var dictatingImages: [UIUserInterfaceStyle: UIImage] = [:]
        for style in [UIUserInterfaceStyle.light, .dark] {
            for (typeSize, suffix) in [(DynamicTypeSize.large, "default"), (.accessibility2, "ax2")] {
                let scheme = style == .dark ? "dark" : "light"
                let dictating = try await render(
                    DictatingScreen(openTab: { _ in }).environment(environment)
                        .environment(\.dynamicTypeSize, typeSize),
                    style: style, name: "render-dictating-idle-\(suffix)-\(scheme)")
                if typeSize == .large { dictatingImages[style] = dictating }
                _ = try await render(
                    NavigationStack {
                        MeetingScreen(openTranscript: { _ in }).toolbar(.hidden, for: .navigationBar)
                    }
                    .environment(environment).environment(\.dynamicTypeSize, typeSize),
                    style: style, name: "render-meeting-idle-\(suffix)-\(scheme)")
            }
        }
        // Dark by design: the Dictating cover draws the same pixels over a light and a dark window.
        let light = try XCTUnwrap(dictatingImages[.light]?.pngData())
        let dark = try XCTUnwrap(dictatingImages[.dark]?.pngData())
        XCTAssertEqual(light, dark, "the Dictating screen changed with the system appearance")
        XCTAssertEqual(environment.dictation.state, .idle, "rendering starts nothing")
        XCTAssertEqual(environment.meeting.state, .idle, "rendering starts nothing")
    }

    /// Presents `cover` full screen from an empty root in a new window with `style`, waits for the presentation, then
    /// draws the window.
    private func render(_ cover: some View, style: UIUserInterfaceStyle, name: String) async throws -> UIImage {
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first, "no window scene")
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: Self.size)
        window.overrideUserInterfaceStyle = style
        window.rootViewController = UIHostingController(
            rootView: Color.clear.fullScreenCover(isPresented: .constant(true)) { cover })
        window.isHidden = false
        defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(1200))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        XCTAssertEqual(image.size.width, Self.size.width, accuracy: 1)
        if let directory = ProcessInfo.processInfo.environment["CHIRP_RENDER_DIR"], !directory.isEmpty {
            let url = URL(fileURLWithPath: directory).appendingPathComponent("\(name).png")
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try XCTUnwrap(image.pngData()).write(to: url)
        }
        return image
    }
}
