import AppIntents

/// App Shortcuts (M2): "Dictate with Parakeet" appears in Shortcuts, Spotlight and Siri with no setup, and is what the
/// person picks for the Action Button (Settings → Action Button → Shortcut) or Back Tap (Accessibility → Touch →
/// Back Tap). Parakeet cannot assign either itself.
struct ParakeetShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ToggleDictationIntent(),
            phrases: [
                "Dictate with \(.applicationName)",
                "Start dictating in \(.applicationName)",
                "Take a note with \(.applicationName)",
            ],
            shortTitle: "Dictate",
            systemImageName: "waveform"
        )
    }
}
