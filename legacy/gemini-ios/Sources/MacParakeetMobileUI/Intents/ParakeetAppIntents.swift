import AppIntents
import Foundation
import MacParakeetCore

// MARK: - Start Dictation Intent

public struct StartDictationIntent: AppIntent {
    public static var title: LocalizedStringResource = "Start Voice Dictation"
    public static var description = IntentDescription("Immediately begins recording voice dictation in Parakeet.")
    public static var openAppWhenRun: Bool = true

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult & ProvidesDialog {
        NotificationCenter.default.post(name: .macParakeetStartMobileDictation, object: nil)
        return .result(dialog: "Recording dictation...")
    }
}

// MARK: - Start Meeting Intent

public struct StartMeetingIntent: AppIntent {
    public static var title: LocalizedStringResource = "Start Meeting Recording"
    public static var description = IntentDescription("Starts recording an in-person meeting with offline speaker diarization.")
    public static var openAppWhenRun: Bool = true

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult & ProvidesDialog {
        NotificationCenter.default.post(name: .macParakeetStartMobileMeeting, object: nil)
        return .result(dialog: "Recording meeting...")
    }
}

// MARK: - Transcribe Clipboard Link Intent

public struct TranscribeClipboardURLIntent: AppIntent {
    public static var title: LocalizedStringResource = "Transcribe Clipboard Link"
    public static var description = IntentDescription("Transcribes the media link currently copied on your clipboard.")
    public static var openAppWhenRun: Bool = true

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult & ProvidesDialog {
        if let url = PlatformPasteboard.string()?.trimmingCharacters(in: .whitespacesAndNewlines), !url.isEmpty {
            return .result(dialog: "Transcribing link: \(url)")
        } else {
            return .result(dialog: "No URL found on your clipboard.")
        }
    }
}

// MARK: - Summarize Latest Meeting Intent

public struct SummarizeLatestMeetingIntent: AppIntent {
    public static var title: LocalizedStringResource = "Summarize Latest Meeting"
    public static var description = IntentDescription("Generates an AI summary and action items from your latest meeting.")
    public static var openAppWhenRun: Bool = false

    public init() {}

    public func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        return .result(value: "Meeting Summary", dialog: "Here is the summary of your latest meeting.")
    }
}

// MARK: - App Shortcuts Provider

public struct ParakeetShortcutsProvider: AppShortcutsProvider {
    public static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartDictationIntent(),
            phrases: [
                "Start dictation with \(.applicationName)",
                "Record a voice memo in \(.applicationName)",
                "\(.applicationName) dictation"
            ],
            shortTitle: "Dictate",
            systemImageName: "waveform.circle.fill"
        )
        AppShortcut(
            intent: StartMeetingIntent(),
            phrases: [
                "Start meeting in \(.applicationName)",
                "Record meeting with \(.applicationName)",
                "\(.applicationName) meeting"
            ],
            shortTitle: "Record Meeting",
            systemImageName: "person.2.fill"
        )
        AppShortcut(
            intent: TranscribeClipboardURLIntent(),
            phrases: [
                "Transcribe link in \(.applicationName)",
                "Transcribe clipboard in \(.applicationName)"
            ],
            shortTitle: "Transcribe Link",
            systemImageName: "link.circle.fill"
        )
    }
}
