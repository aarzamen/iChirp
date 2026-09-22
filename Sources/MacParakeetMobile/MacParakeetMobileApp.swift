import SwiftUI
import MacParakeetCore
import MacParakeetViewModels
import MacParakeetMobileUI

/// Main application entry point for MacParakeet on iOS.
/// Renders the native mobile interface, initializes memory pressure coordination,
/// and sets up the App Group keyboard dictation IPC server.
@main
struct MacParakeetMobileApp: App {

    init() {
        // Register memory pressure monitoring to prevent Jetsam kills
        _ = IOSMemoryPressureCoordinator.shared

        // Set up the keyboard dictation bridge IPC server
        KeyboardDictationServer.shared.onStartRequested = {
            Task { @MainActor in
                NotificationCenter.default.post(name: .macParakeetStartMobileDictation, object: nil)
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            IOSMainTabView()
                .tint(MobileDesignSystem.Colors.accent)
                .background(MobileDesignSystem.Colors.background.ignoresSafeArea())
        }
    }
}
