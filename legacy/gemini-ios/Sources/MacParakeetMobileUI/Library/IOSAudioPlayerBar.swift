import SwiftUI
import MacParakeetCore

/// Bottom audio playback control bar with scrubber, play/pause, and speed multiplier.
public struct IOSAudioPlayerBar: View {
    @Binding public var isPlaying: Bool
    @Binding public var currentProgress: Double // 0.0 to 1.0
    @Binding public var playbackRate: Float // 1.0, 1.25, 1.5, 2.0
    public let totalDurationMs: Int
    public let onPlayPause: () -> Void
    public let onSeek: (Double) -> Void

    public init(
        isPlaying: Binding<Bool>,
        currentProgress: Binding<Double>,
        playbackRate: Binding<Float>,
        totalDurationMs: Int,
        onPlayPause: @escaping () -> Void,
        onSeek: @escaping (Double) -> Void
    ) {
        self._isPlaying = isPlaying
        self._currentProgress = currentProgress
        self._playbackRate = playbackRate
        self.totalDurationMs = totalDurationMs
        self.onPlayPause = onPlayPause
        self.onSeek = onSeek
    }

    private var currentTimeFormatted: String {
        let currentMs = Int(Double(totalDurationMs) * currentProgress)
        let totalSec = currentMs / 1000
        return String(format: "%d:%02d", totalSec / 60, totalSec % 60)
    }

    private var totalTimeFormatted: String {
        let totalSec = totalDurationMs / 1000
        return String(format: "%d:%02d", totalSec / 60, totalSec % 60)
    }

    public var body: some View {
        VStack(spacing: 8) {
            // Scrubber Slider
            HStack(spacing: 8) {
                Text(currentTimeFormatted)
                    .font(MobileDesignSystem.Typography.monoTimestamp)
                    .foregroundColor(MobileDesignSystem.Colors.textTertiary)
                    .frame(width: 40, alignment: .leading)

                Slider(value: $currentProgress, in: 0...1, onEditingChanged: { editing in
                    if !editing {
                        onSeek(currentProgress)
                    }
                })
                .tint(MobileDesignSystem.Colors.accent)

                Text(totalTimeFormatted)
                    .font(MobileDesignSystem.Typography.monoTimestamp)
                    .foregroundColor(MobileDesignSystem.Colors.textTertiary)
                    .frame(width: 40, alignment: .trailing)
            }

            // Controls
            HStack(spacing: MobileDesignSystem.Spacing.lg) {
                // Rewind 15s
                Button(action: {
                    MobileDesignSystem.Haptics.light()
                    let step = 15.0 / (Double(max(totalDurationMs, 1000)) / 1000.0)
                    currentProgress = max(0, currentProgress - step)
                    onSeek(currentProgress)
                }) {
                    Image(systemName: "gobackward.15")
                        .font(.system(size: 20))
                        .foregroundColor(MobileDesignSystem.Colors.textSecondary)
                }

                // Play / Pause
                Button(action: {
                    MobileDesignSystem.Haptics.medium()
                    onPlayPause()
                }) {
                    Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 44))
                        .foregroundColor(MobileDesignSystem.Colors.accent)
                }

                // Forward 15s
                Button(action: {
                    MobileDesignSystem.Haptics.light()
                    let step = 15.0 / (Double(max(totalDurationMs, 1000)) / 1000.0)
                    currentProgress = min(1, currentProgress + step)
                    onSeek(currentProgress)
                }) {
                    Image(systemName: "goforward.15")
                        .font(.system(size: 20))
                        .foregroundColor(MobileDesignSystem.Colors.textSecondary)
                }

                Spacer()

                // Speed button
                Button(action: cyclePlaybackRate) {
                    Text(String(format: "%.2gx", playbackRate))
                        .font(MobileDesignSystem.Typography.monoTimestamp)
                        .foregroundColor(MobileDesignSystem.Colors.accent)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(MobileDesignSystem.Colors.surfaceElevated)
                        .clipShape(Capsule())
                }
            }
        }
        .padding(MobileDesignSystem.Spacing.md)
        .background(MobileDesignSystem.Colors.surface)
        .clipShape(RoundedRectangle(cornerRadius: MobileDesignSystem.CornerRadius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: MobileDesignSystem.CornerRadius.lg, style: .continuous)
                .stroke(MobileDesignSystem.Colors.border, lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.08), radius: 8, y: 4)
    }

    private func cyclePlaybackRate() {
        MobileDesignSystem.Haptics.light()
        if playbackRate < 1.2 {
            playbackRate = 1.25
        } else if playbackRate < 1.4 {
            playbackRate = 1.5
        } else if playbackRate < 1.8 {
            playbackRate = 2.0
        } else {
            playbackRate = 1.0
        }
    }
}
