import SwiftUI

/// The speaker-attribution row used above every transcript paragraph
/// (`docs/design/2026-09-21-iphone-canvas/Meeting.dc.html`,
/// `docs/design/2026-09-21-iphone-canvas/Transcript.dc.html`): a colored dot, the speaker's
/// label in that speaker's ink color, and an optional tabular-figure timestamp.
public struct SpeakerDot: View {
    public var label: String
    public var timestamp: String?
    /// The speaker's position in first-speech order; resolved to a color pair via
    /// `Tokens.Color.speaker(at:)`.
    public var speakerIndex: Int

    public init(label: String, timestamp: String? = nil, speakerIndex: Int) {
        self.label = label
        self.timestamp = timestamp
        self.speakerIndex = speakerIndex
    }

    public var body: some View {
        let palette = Tokens.Color.speaker(at: speakerIndex)
        HStack(spacing: 7) {
            Circle()
                .fill(palette.dot)
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)  // Decorative; the speaker's name/timestamp carry the info.
            Text(label)
                .font(.system(size: 12.5, weight: .bold))
                .foregroundStyle(palette.ink)
            if let timestamp {
                Text(timestamp)
                    .font(.system(size: 11, weight: .regular))
                    .monospacedDigit()
                    .foregroundStyle(Tokens.Color.secondary)
            }
        }
        // One VoiceOver stop for the whole row, read as "<label>, <timestamp>" (e.g.
        // "Senior Chief, 03:41") rather than three separate swipe stops.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(timestamp.map { "\(label), \($0)" } ?? label)
    }
}

#Preview("SpeakerDot") {
    VStack(alignment: .leading, spacing: 10) {
        SpeakerDot(label: "Senior Chief", timestamp: "03:41", speakerIndex: 0)
        SpeakerDot(label: "Ops", timestamp: "03:58", speakerIndex: 1)
        SpeakerDot(label: "You", timestamp: "04:06", speakerIndex: 2)
        SpeakerDot(label: "Speaker 4", timestamp: "04:22", speakerIndex: 3)
        // Wraps back to blue past the four-color palette.
        SpeakerDot(label: "Speaker 5", timestamp: "04:40", speakerIndex: 4)
    }
    .padding(24)
    .background(Tokens.Color.ground)
}
