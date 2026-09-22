import SwiftUI

/// Animated audio waveform visualizer for the iOS recording interface.
/// Displays dynamic vertical frequency/amplitude bars with warm coral gradient glow.
public struct IOSWaveformVisualizer: View {
    public let isRecording: Bool
    public let audioLevel: Float // 0.0 to 1.0
    public let barCount: Int

    @State private var phase: Double = 0.0

    public init(isRecording: Bool, audioLevel: Float, barCount: Int = 24) {
        self.isRecording = isRecording
        self.audioLevel = audioLevel
        self.barCount = barCount
    }

    public var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            HStack(spacing: 3) {
                ForEach(0..<barCount, id: \.self) { index in
                    let normalizedIndex = Double(index) / Double(barCount)
                    let barHeight = computeBarHeight(for: normalizedIndex, time: timeline.date.timeIntervalSinceReferenceDate)

                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    MobileDesignSystem.Colors.accent,
                                    MobileDesignSystem.Colors.accentLight
                                ],
                                startPoint: .bottom,
                                endPoint: .top
                            )
                        )
                        .frame(width: 3, height: max(4, barHeight))
                        .animation(.easeOut(duration: 0.1), value: barHeight)
                }
            }
            .frame(height: 64)
            .padding(.horizontal, MobileDesignSystem.Spacing.md)
        }
    }

    private func computeBarHeight(for normalizedIndex: Double, time: TimeInterval) -> CGFloat {
        guard isRecording else {
            // Idle breathing wave
            let idleSine = sin(time * 2.0 + normalizedIndex * .pi * 2)
            return CGFloat(6 + idleSine * 3)
        }

        // Active recording: combination of audio level + dynamic frequencies
        let wave1 = sin(time * 6.0 + normalizedIndex * 4.0)
        let wave2 = cos(time * 9.0 + normalizedIndex * 6.0)
        let baseVariance = (wave1 + wave2) * 0.25 + 0.5
        let levelClamped = min(max(CGFloat(audioLevel), 0.05), 1.0)
        let height = levelClamped * 56.0 * baseVariance

        return CGFloat(min(max(height, 4), 60))
    }
}
