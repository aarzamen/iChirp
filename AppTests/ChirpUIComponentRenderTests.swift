import ChirpUI
import SwiftUI
import UIKit
import XCTest

/// Plan 024 Task 11: the shared ChirpUI components that the screen lanes adopt, rendered on the iPhone simulator in
/// light and dark at the default text size and at AX3. `swift test` runs on the Mac, where SwiftUI applies no Dynamic
/// Type, so this is where "grows with the text" is checked: every component is taller at AX3, the action bar re-flows to
/// two columns instead of shrinking "Transform" (R7-12), the segmented control becomes a list (R7-4), and the
/// `ChirpTextField` placeholder draws in the text-safe placeholder color rather than the system grey (R7-3).
///
/// Each sample is the root of a `UIHostingController` in its own window, drawn with `drawHierarchy` (which, unlike
/// `ImageRenderer`, draws the UIKit-backed `TextField`). Nothing here touches the app's data. With `CHIRP_RENDER_DIR`
/// set (`TEST_RUNNER_CHIRP_RENDER_DIR=<dir>` through xcodebuild) the images are written there for review.
@MainActor
final class ChirpUIComponentRenderTests: XCTestCase {
    private static let width: CGFloat = 402  // iPhone 17 Pro

    private struct Rendered {
        let size: CGSize
        let image: UIImage
    }

    // MARK: - Samples

    private enum Sample: String, CaseIterable {
        case buttons, actionBar, segmented, toggle, textField, card, mark

        @MainActor @ViewBuilder var view: some View {
            switch self {
            case .buttons:
                VStack(spacing: Tokens.Spacing.s) {
                    Button {
                    } label: {
                        Label("Create", systemImage: "sparkles")
                    }
                    .buttonStyle(.chirpPrimary)
                    ChirpButtonRow {
                        Button("Create another") {}.buttonStyle(.chirpSecondary)
                        Button("Done") {}.buttonStyle(.chirpPrimary)
                    }
                    Button("Stop & save") {}.buttonStyle(.chirp(.stop))
                    Button("Create") {}.buttonStyle(.chirpPrimary).disabled(true)
                    HStack {
                        Button("Retry") {}.buttonStyle(.chirp(.tinted, size: .compact))
                        Button("Delete") {}.buttonStyle(.chirp(.destructive, size: .compact))
                        Spacer()
                    }
                }
                .padding(Tokens.Spacing.sheetGutter)
            case .actionBar:
                ChirpActionBar {
                    ChirpActionBarItem("Copy", systemImage: "doc.on.doc") {}
                    ChirpActionBarItem("Share", systemImage: "square.and.arrow.up") {}
                    ChirpActionBarItem("Listen", systemImage: "speaker.wave.2") {}
                    ChirpActionBarItem("Transform", systemImage: "sparkles", emphasized: true) {}
                }
            case .segmented:
                VStack(alignment: .leading, spacing: Tokens.Spacing.m) {
                    ChirpSegmentedControl(
                        "View", selection: .constant(0),
                        segments: [.init("Notes", value: 0), .init("Live transcript", value: 1)], width: .fill)
                    ChirpSegmentedControl(
                        "Engine", selection: .constant(1),
                        segments: [.init("Needle", value: 0, isEnabled: false), .init("Rules (basic)", value: 1)])
                }
                .padding(Tokens.Spacing.sheetGutter)
            case .toggle:
                VStack(spacing: 0) {
                    Toggle("Keep dictation audio", isOn: .constant(true)).toggleStyle(.chirp)
                    Toggle("Speaker labels", isOn: .constant(false)).toggleStyle(.chirp)
                }
                .padding(.horizontal, Tokens.Spacing.m)
                .chirpCard(padding: 0)
                .padding(Tokens.Spacing.sheetGutter)
            case .textField:
                ChirpTextField("Search titles, text and speakers", text: .constant(""))
                    .padding(.horizontal, Tokens.Spacing.s)
                    .frame(minHeight: Tokens.Metric.minTapTarget)
                    .background(ChirpCardBackground(radius: Tokens.Radius.cover))
                    .padding(Tokens.Spacing.sheetGutter)
            case .card:
                VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
                    Text("Weekly sync").font(.headline).foregroundStyle(Tokens.Color.ink)
                    Text("Meeting · 28:40 · 4 speakers").font(.footnote).foregroundStyle(Tokens.Color.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .chirpCard()
                .padding(Tokens.Spacing.sheetGutter)
            case .mark:
                HStack(spacing: Tokens.Spacing.xs) {
                    ParakeetMarkView().chirpScaledFrame(width: 24, height: 24, relativeTo: .title2)
                    Text("Parakeet").font(Tokens.Font.rounded(22)).foregroundStyle(Tokens.Color.ink)
                    Spacer()
                }
                .padding(Tokens.Spacing.sheetGutter)
            }
        }
    }

    // MARK: - Tests

    func testEveryComponentRendersInLightAndDarkAndGrowsAtAX3() throws {
        for sample in Sample.allCases {
            var heights: [DynamicTypeSize: CGFloat] = [:]
            for typeSize in [DynamicTypeSize.large, .accessibility3] {
                for style in [UIUserInterfaceStyle.light, .dark] {
                    let rendered = try render(sample.view, typeSize: typeSize, style: style, name: sample.rawValue)
                    XCTAssertEqual(rendered.image.size.width, Self.width, accuracy: 1, "\(sample)")
                    heights[typeSize] = rendered.size.height
                }
            }
            let standard = try XCTUnwrap(heights[.large])
            let large = try XCTUnwrap(heights[.accessibility3])
            XCTAssertGreaterThan(large, standard, "\(sample) does not grow with Dynamic Type (\(standard) → \(large))")
        }
    }

    func testActionBarIsOneRowByDefaultAndTwoRowsAtAX3() throws {
        let standard = try render(Sample.actionBar.view, typeSize: .large, style: .light, name: nil)
        XCTAssertEqual(standard.size.height, Tokens.Metric.actionBarHeight, accuracy: 2, "one row of four")
        let large = try render(Sample.actionBar.view, typeSize: .accessibility3, style: .light, name: nil)
        XCTAssertGreaterThanOrEqual(
            large.size.height, 2 * Tokens.Metric.actionBarHeight, "AX3: two rows rather than a shrunken \"Transform\"")
    }

    func testSegmentedControlBecomesAListWhenTitlesNoLongerFit() throws {
        // Side by side at the default size; far too wide for one row at AX3 (two-word titles in a 402 pt row).
        let control = ChirpSegmentedControl(
            "Speak", selection: .constant(false),
            segments: [.init("The whole text", value: false), .init("A short summary", value: true)], width: .fill)
        // A control whose titles still fit side by side at AX3: one row's height there.
        let short = ChirpSegmentedControl(
            "Version", selection: .constant(0), segments: [.init("v3", value: 0), .init("v2", value: 1)])
        let standard = try render(control, typeSize: .large, style: .light, name: "segmented-voice")
        let large = try render(control, typeSize: .accessibility3, style: .light, name: "segmented-voice")
        let oneRow = try render(short, typeSize: .accessibility3, style: .light, name: nil)
        XCTAssertEqual(standard.size.height, Tokens.Metric.minTapTarget, accuracy: 1, "one row by default")
        XCTAssertGreaterThan(large.size.height, 1.5 * oneRow.size.height, "a stacked list at AX3, not one row")
    }

    func testTextFieldPlaceholderDrawsInThePlaceholderColorNotTheSystemGrey() throws {
        // R7-3: the system placeholder is 1.72:1 on white and 2.47:1 on the dark surface. The strongest placeholder
        // pixel must reach the placeholder token's contrast against the surface (4.5:1; 4.3 allows antialiasing).
        for style in [UIUserInterfaceStyle.light, .dark] {
            let rendered = try render(Sample.textField.view, typeSize: .large, style: style, name: nil)
            let surface = Tokens.Palette.surface.hex(in: style == .dark ? .dark : .light)
            let extreme = try XCTUnwrap(Self.extremePixel(in: rendered.image, darkest: style == .light))
            let ratio = Self.contrastRatio(extreme, surface)
            XCTAssertGreaterThanOrEqual(
                ratio, 4.3,
                String(format: "placeholder %06X on surface is %.2f:1 in %@", extreme, ratio, style.rawName))
        }
    }

    // MARK: - Rendering

    /// Hosts `view` (on `ground`, 402 pt wide, at `typeSize`) as the root of a window with `style`, sized to fit,
    /// and draws the window.
    private func render(
        _ view: some View, typeSize: DynamicTypeSize, style: UIUserInterfaceStyle, name: String?
    ) throws -> Rendered {
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first, "no window scene")
        let root =
            view
            .frame(width: Self.width)
            .background(Tokens.Color.ground)
            .environment(\.dynamicTypeSize, typeSize)
        let host = UIHostingController(rootView: root)
        host.safeAreaRegions = []
        host.overrideUserInterfaceStyle = style
        let fitting = host.sizeThatFits(in: CGSize(width: Self.width, height: .greatestFiniteMagnitude))
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: Self.width, height: ceil(fitting.height))
        window.overrideUserInterfaceStyle = style
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true }
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        if let name, let directory = ProcessInfo.processInfo.environment["CHIRP_RENDER_DIR"], !directory.isEmpty {
            let size = typeSize == .large ? "default" : "ax3"
            let url = URL(fileURLWithPath: directory).appendingPathComponent(
                "chirpui-\(name)-\(size)-\(style.rawName).png")
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try XCTUnwrap(image.pngData()).write(to: url)
        }
        return Rendered(size: fitting, image: image)
    }

    // MARK: - Pixels and contrast

    /// The darkest (or brightest) pixel of `image` as `0xRRGGBB`.
    private static func extremePixel(in image: UIImage, darkest: Bool) -> UInt32? {
        guard let cgImage = image.cgImage else { return nil }
        let width = cgImage.width
        let height = cgImage.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard
                let context = CGContext(
                    data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        var best: UInt32?
        var bestLuminance = darkest ? Double.infinity : -Double.infinity
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let hex = (UInt32(pixels[index]) << 16) | (UInt32(pixels[index + 1]) << 8) | UInt32(pixels[index + 2])
            let value = luminance(hex)
            if darkest ? value < bestLuminance : value > bestLuminance {
                bestLuminance = value
                best = hex
            }
        }
        return best
    }

    private static func luminance(_ hex: UInt32) -> Double {
        func linear(_ channel: Double) -> Double {
            channel <= 0.03928 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        let rgb = Tokens.Color.rgbComponents(fromHex: hex)
        return 0.2126 * linear(rgb.red) + 0.7152 * linear(rgb.green) + 0.0722 * linear(rgb.blue)
    }

    private static func contrastRatio(_ a: UInt32, _ b: UInt32) -> Double {
        let (l1, l2) = (luminance(a), luminance(b))
        return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
    }
}

extension UIUserInterfaceStyle {
    fileprivate var rawName: String { self == .dark ? "dark" : "light" }
}
