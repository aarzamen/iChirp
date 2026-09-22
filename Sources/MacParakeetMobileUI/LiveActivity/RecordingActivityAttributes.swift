import SwiftUI
#if canImport(ActivityKit) && os(iOS)
import ActivityKit

/// Attributes and dynamic state for Dynamic Island and Lock Screen Live Activities.
public struct RecordingActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable, Sendable {
        public var isPaused: Bool
        public var elapsedSeconds: Int
        public var audioLevel: Float
        public var captureMode: String

        public init(
            isPaused: Bool,
            elapsedSeconds: Int,
            audioLevel: Float = 0.0,
            captureMode: String = "Dictation"
        ) {
            self.isPaused = isPaused
            self.elapsedSeconds = elapsedSeconds
            self.audioLevel = audioLevel
            self.captureMode = captureMode
        }

        public var formattedTime: String {
            let minutes = elapsedSeconds / 60
            let seconds = elapsedSeconds % 60
            return String(format: "%02d:%02d", minutes, seconds)
        }
    }

    public var sessionID: UUID
    public var title: String

    public init(sessionID: UUID = UUID(), title: String = "Voice Recording") {
        self.sessionID = sessionID
        self.title = title
    }
}
#else
public struct RecordingActivityAttributes: Sendable {
    public struct ContentState: Codable, Hashable, Sendable {
        public var isPaused: Bool
        public var elapsedSeconds: Int
        public var audioLevel: Float
        public var captureMode: String

        public init(
            isPaused: Bool,
            elapsedSeconds: Int,
            audioLevel: Float = 0.0,
            captureMode: String = "Dictation"
        ) {
            self.isPaused = isPaused
            self.elapsedSeconds = elapsedSeconds
            self.audioLevel = audioLevel
            self.captureMode = captureMode
        }

        public var formattedTime: String {
            let minutes = elapsedSeconds / 60
            let seconds = elapsedSeconds % 60
            return String(format: "%02d:%02d", minutes, seconds)
        }
    }

    public var sessionID: UUID
    public var title: String

    public init(sessionID: UUID = UUID(), title: String = "Voice Recording") {
        self.sessionID = sessionID
        self.title = title
    }
}
#endif

/// Presentation view for the Live Activity banner on the Lock Screen.
public struct RecordingLiveActivityView: View {
    public let isPaused: Bool
    public let elapsedSeconds: Int
    public let title: String
    public let captureMode: String

    public init(
        isPaused: Bool,
        elapsedSeconds: Int,
        title: String = "Voice Recording",
        captureMode: String = "Dictation"
    ) {
        self.isPaused = isPaused
        self.elapsedSeconds = elapsedSeconds
        self.title = title
        self.captureMode = captureMode
    }

    private var formattedTime: String {
        let minutes = elapsedSeconds / 60
        let seconds = elapsedSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    public var body: some View {
        HStack(spacing: MobileDesignSystem.Spacing.md) {
            // Pulsing Coral Mic / Wave Icon
            ZStack {
                Circle()
                    .fill(isPaused ? MobileDesignSystem.Colors.warningAmber.opacity(0.2) : MobileDesignSystem.Colors.accentLight)
                    .frame(width: 44, height: 44)

                Image(systemName: isPaused ? "pause.fill" : "waveform")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(isPaused ? MobileDesignSystem.Colors.warningAmber : MobileDesignSystem.Colors.accent)
            }

            // Title & Mode
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(MobileDesignSystem.Typography.headline)
                    .foregroundColor(MobileDesignSystem.Colors.textPrimary)

                Text(captureMode.uppercased())
                    .font(MobileDesignSystem.Typography.caption)
                    .foregroundColor(MobileDesignSystem.Colors.textSecondary)
                    .tracking(1)
            }

            Spacer()

            // Timer
            VStack(alignment: .trailing, spacing: 2) {
                Text(formattedTime)
                    .font(MobileDesignSystem.Typography.monoTimer)
                    .font(.system(size: 24))
                    .foregroundColor(isPaused ? MobileDesignSystem.Colors.warningAmber : MobileDesignSystem.Colors.accent)

                Text(isPaused ? "PAUSED" : "REC")
                    .font(MobileDesignSystem.Typography.caption)
                    .foregroundColor(isPaused ? MobileDesignSystem.Colors.warningAmber : MobileDesignSystem.Colors.errorRed)
                    .tracking(2)
            }
        }
        .padding(MobileDesignSystem.Spacing.md)
        .background(MobileDesignSystem.Colors.surface)
        .clipShape(RoundedRectangle(cornerRadius: MobileDesignSystem.CornerRadius.lg))
    }
}
