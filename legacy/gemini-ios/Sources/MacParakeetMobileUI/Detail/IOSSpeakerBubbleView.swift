import SwiftUI
import MacParakeetCore

/// Renders a single diarized speaker utterance block with speaker badge and timecode.
public struct IOSSpeakerBubbleView: View {
    public let segment: TranscriptSegmentRecord
    public let speakerIndex: Int
    public let isPlaying: Bool
    public let onSeek: (Int) -> Void

    public init(
        segment: TranscriptSegmentRecord,
        speakerIndex: Int,
        isPlaying: Bool = false,
        onSeek: @escaping (Int) -> Void
    ) {
        self.segment = segment
        self.speakerIndex = speakerIndex
        self.isPlaying = isPlaying
        self.onSeek = onSeek
    }

    private var speakerColor: Color {
        MobileDesignSystem.Colors.speakerColor(for: speakerIndex)
    }

    private var formattedTime: String {
        let startSec = segment.startMs / 1000
        let min = startSec / 60
        let sec = startSec % 60
        return String(format: "%d:%02d", min, sec)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                // Speaker badge
                HStack(spacing: 5) {
                    Circle()
                        .fill(speakerColor)
                        .frame(width: 8, height: 8)

                    Text(segment.speakerLabel)
                        .font(MobileDesignSystem.Typography.headline)
                        .foregroundColor(speakerColor)
                }

                // Timecode
                Button(action: {
                    MobileDesignSystem.Haptics.light()
                    onSeek(segment.startMs)
                }) {
                    HStack(spacing: 3) {
                        Image(systemName: isPlaying ? "speaker.wave.2.fill" : "play.circle")
                            .font(.system(size: 11))
                        Text(formattedTime)
                            .font(MobileDesignSystem.Typography.monoTimestamp)
                    }
                    .foregroundColor(isPlaying ? MobileDesignSystem.Colors.accent : MobileDesignSystem.Colors.textTertiary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(MobileDesignSystem.Colors.surfaceElevated)
                    .clipShape(Capsule())
                }

                Spacer()
            }

            // Utterance text
            Text(segment.text)
                .font(MobileDesignSystem.Typography.body)
                .foregroundColor(MobileDesignSystem.Colors.textPrimary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(MobileDesignSystem.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: MobileDesignSystem.CornerRadius.md, style: .continuous)
                .fill(isPlaying ? MobileDesignSystem.Colors.accentLight : MobileDesignSystem.Colors.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: MobileDesignSystem.CornerRadius.md, style: .continuous)
                .stroke(isPlaying ? MobileDesignSystem.Colors.accent.opacity(0.4) : MobileDesignSystem.Colors.border, lineWidth: 1)
        )
    }
}
