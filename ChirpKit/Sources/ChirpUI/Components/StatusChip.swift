import SwiftUI

/// A capsule status chip: an optional icon (an SF Symbol or a colored dot) plus a label, in the
/// surface/tint/badge fills the canvas uses for things like the "On device" lock chip,
/// "Clean text on copy", and "Partial audio". Compose one directly, or use one of the static
/// factories below for the recurring cases.
public struct StatusChip: View {
    public enum Icon {
        case system(String)
        case dot(Color)
        case none
    }

    public var text: String
    public var icon: Icon
    public var ink: Color
    public var fill: Color
    public var border: Color

    public init(
        _ text: String, icon: Icon = .none, ink: Color = Tokens.Color.secondary, fill: Color = Tokens.Color.surface,
        border: Color = Tokens.Color.border
    ) {
        self.text = text
        self.icon = icon
        self.ink = ink
        self.fill = fill
        self.border = border
    }

    public var body: some View {
        HStack(spacing: 6) {
            switch icon {
            case .system(let name):
                Image(systemName: name)
                    .font(.system(size: 11, weight: .semibold))
            case .dot(let color):
                Circle()
                    .fill(color)
                    .frame(width: 6, height: 6)
            case .none:
                EmptyView()
            }
            Text(text)
                .font(.system(size: 11.5, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundStyle(ink)
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(fill)
        .clipShape(Capsule())
        .overlay(Capsule().stroke(border, lineWidth: 1))
    }
}

extension StatusChip {
    /// Capture header's "On device" chip: a lock glyph on a plain surface pill.
    public static func onDevice() -> StatusChip {
        StatusChip("On device", icon: .system("lock.fill"))
    }

    /// Dictate's "Clean text on copy" chip: a success-green dot on a tint pill with accent-ink
    /// text.
    public static func cleanTextOnCopy() -> StatusChip {
        StatusChip(
            "Clean text on copy",
            icon: .dot(Tokens.Color.success),
            ink: Tokens.Color.accentInk,
            fill: Tokens.Color.surface,
            border: Tokens.Color.tintBorderSelected
        )
    }

    /// An in-progress transcription readout, e.g. "Transcribing · 62%".
    public static func transcribing(percent: Int) -> StatusChip {
        StatusChip(
            "Transcribing · \(percent)%",
            ink: Tokens.Color.accentInk,
            fill: Tokens.Color.tint,
            border: Tokens.Color.tintBorder
        )
    }

    /// Library's "Partial audio" badge on a recovered meeting.
    public static func partialAudio() -> StatusChip {
        StatusChip(
            "Partial audio", ink: Tokens.Color.partialAudioInk, fill: Tokens.Color.partialAudioFill, border: .clear)
    }
}

#Preview("StatusChip") {
    VStack(alignment: .leading, spacing: 10) {
        StatusChip.onDevice()
        StatusChip.cleanTextOnCopy()
        StatusChip.transcribing(percent: 62)
        StatusChip.partialAudio()
    }
    .padding(24)
    .background(Tokens.Color.ground)
}
