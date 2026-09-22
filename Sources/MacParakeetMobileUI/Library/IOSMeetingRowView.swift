import SwiftUI
import MacParakeetCore

/// Renders a single row in the Library list with metadata, tags, and swipe actions.
public struct IOSMeetingRowView: View {
    public let title: String
    public let previewText: String
    public let date: Date
    public let durationMs: Int
    public let speakerCount: Int?
    public let isMeeting: Bool
    public let onCopy: () -> Void
    public let onShare: () -> Void
    public let onDelete: () -> Void

    public init(
        title: String,
        previewText: String,
        date: Date,
        durationMs: Int,
        speakerCount: Int? = nil,
        isMeeting: Bool = true,
        onCopy: @escaping () -> Void,
        onShare: @escaping () -> Void,
        onDelete: @escaping () -> Void
    ) {
        self.title = title
        self.previewText = previewText
        self.date = date
        self.durationMs = durationMs
        self.speakerCount = speakerCount
        self.isMeeting = isMeeting
        self.onCopy = onCopy
        self.onShare = onShare
        self.onDelete = onDelete
    }

    private var formattedDuration: String {
        let sec = durationMs / 1000
        let min = sec / 60
        let remainderSec = sec % 60
        if min >= 60 {
            let hr = min / 60
            return String(format: "%dh %02dm", hr, min % 60)
        }
        return String(format: "%d:%02d", min, remainderSec)
    }

    private var formattedDate: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                // Type icon
                Image(systemName: isMeeting ? "person.2.fill" : "waveform")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(isMeeting ? MobileDesignSystem.Colors.accent : MobileDesignSystem.Colors.textSecondary)

                // Title
                Text(title.isEmpty ? (isMeeting ? "Meeting Recording" : "Voice Dictation") : title)
                    .font(MobileDesignSystem.Typography.headline)
                    .foregroundColor(MobileDesignSystem.Colors.textPrimary)
                    .lineLimit(1)

                Spacer()

                // Relative date
                Text(formattedDate)
                    .font(MobileDesignSystem.Typography.caption)
                    .foregroundColor(MobileDesignSystem.Colors.textTertiary)
            }

            // Preview Snippet
            if !previewText.isEmpty {
                Text(previewText)
                    .font(MobileDesignSystem.Typography.bodySmall)
                    .foregroundColor(MobileDesignSystem.Colors.textSecondary)
                    .lineLimit(2)
                    .lineSpacing(2)
            }

            // Bottom metadata badges
            HStack(spacing: 8) {
                // Duration
                HStack(spacing: 3) {
                    Image(systemName: "clock")
                        .font(.system(size: 10))
                    Text(formattedDuration)
                        .font(MobileDesignSystem.Typography.monoTimestamp)
                }
                .foregroundColor(MobileDesignSystem.Colors.textTertiary)

                // Speaker count
                if let count = speakerCount, count > 1 {
                    HStack(spacing: 3) {
                        Image(systemName: "person.2")
                            .font(.system(size: 10))
                        Text("\(count) speakers")
                            .font(MobileDesignSystem.Typography.caption)
                    }
                    .foregroundColor(MobileDesignSystem.Colors.textTertiary)
                }

                Spacer()
            }
            .padding(.top, 2)
        }
        .padding(.vertical, 4)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive, action: {
                MobileDesignSystem.Haptics.heavy()
                onDelete()
            }) {
                Label("Delete", systemImage: "trash")
            }

            Button(action: {
                MobileDesignSystem.Haptics.light()
                onShare()
            }) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            .tint(.blue)

            Button(action: {
                MobileDesignSystem.Haptics.light()
                onCopy()
            }) {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .tint(MobileDesignSystem.Colors.accent)
        }
    }
}
