import SwiftUI

/// A palette-aware switch (R7-5, plan 024 Task 11): the green `success` track when on, the warm `toggleOffTrack` when
/// off (the stock switch draws a cool iOS grey there), a white knob, and a switch that grows with Dynamic Type up to
/// 1.5× so it does not shrink beside large labels (R7-4).
///
/// ```swift
/// Toggle("Keep dictation audio", isOn: $keepAudio).toggleStyle(.chirp)
/// ```
///
/// The label sits leading and the switch trailing, like the stock style; the whole row toggles. VoiceOver reads the
/// label, the "switch button" trait and On or Off, and a double tap toggles it. A disabled toggle (`.disabled(true)`)
/// ignores taps, dims its switch and draws its label in `secondary`.
public struct ChirpToggleStyle: ToggleStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        ChirpToggleBody(configuration: configuration)
    }
}

extension ToggleStyle where Self == ChirpToggleStyle {
    /// The palette-aware switch. See `ChirpToggleStyle`.
    public static var chirp: ChirpToggleStyle { ChirpToggleStyle() }
}

private struct ChirpToggleBody: View {
    let configuration: ToggleStyleConfiguration

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The stock switch's 31 pt height, growing with body text up to 1.5×.
    @ScaledMetric(relativeTo: .body) private var scaledTrackHeight: CGFloat = 31

    private var trackHeight: CGFloat { Tokens.Scale.capped(scaledTrackHeight, base: 31, maxScale: 1.5) }
    private var trackWidth: CGFloat { trackHeight * 51 / 31 }
    private var knobInset: CGFloat { 2 }

    var body: some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: Tokens.Spacing.s) {
                configuration.label
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // Disabled: a legible `secondary` label (4.5:1), not a half-transparent one.
                    .foregroundStyle(isEnabled ? Tokens.Color.ink : Tokens.Color.secondary)
                track
                    .opacity(isEnabled ? 1 : 0.5)
            }
            .frame(minHeight: Tokens.Metric.minTapTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(ChirpUndimmedButtonStyle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(configuration.isOn ? "On" : "Off")
    }

    private var track: some View {
        Capsule()
            .fill(configuration.isOn ? Tokens.Color.success : Tokens.Color.toggleOffTrack)
            .frame(width: trackWidth, height: trackHeight)
            .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                Circle()
                    .fill(Tokens.Color.onAccent)
                    .shadow(
                        color: Tokens.Color.raisedShadow, radius: Tokens.Metric.raisedShadowRadius,
                        y: Tokens.Metric.raisedShadowY
                    )
                    .padding(knobInset)
            }
            .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: configuration.isOn)
            .accessibilityHidden(true)
    }
}

#Preview("ChirpToggleStyle") {
    @Previewable @State var keep = true
    @Previewable @State var labels = false
    VStack(spacing: 0) {
        Toggle("Keep dictation audio", isOn: $keep).toggleStyle(.chirp)
        Toggle("Speaker labels", isOn: $labels).toggleStyle(.chirp)
        Toggle("Disabled", isOn: .constant(true)).toggleStyle(.chirp).disabled(true)
    }
    .padding(.horizontal, Tokens.Spacing.m)
    .chirpCard(padding: 0)
    .padding(Tokens.Spacing.xl)
    .background(Tokens.Color.ground)
}
