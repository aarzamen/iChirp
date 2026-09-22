import ChirpUI
import SwiftUI

/// The four tabs, in the canvas order.
enum AppTab: Hashable {
    case capture, library, transforms, settings
}

struct RootTabView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var selection: AppTab = .capture

    var body: some View {
        TabView(selection: $selection) {
            Tab(value: AppTab.capture) {
                CaptureScreen(openTab: { selection = $0 })
            } label: {
                tabLabel("Capture", "waveform")
            }
            Tab(value: AppTab.library) {
                LibraryScreen()
            } label: {
                tabLabel("Library", "square.grid.2x2")
            }
            Tab(value: AppTab.transforms) {
                TransformsScreen()
            } label: {
                tabLabel("Transforms", "sparkles")
            }
            Tab(value: AppTab.settings) {
                SettingsScreen()
            } label: {
                tabLabel("Settings", "gearshape")
            }
        }
        .tint(AppColor.accentText)
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .onOpenURL { url in
            // Share sheet → Parakeet (or Files → Open in): show Capture, where the new Recent row appears.
            selection = .capture
            environment.openIncoming(url)
        }
    }

    /// The canvas draws outline glyphs; the tab bar would otherwise switch to the filled variants.
    private func tabLabel(_ title: String, _ systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .environment(\.symbolVariants, .none)
    }
}
