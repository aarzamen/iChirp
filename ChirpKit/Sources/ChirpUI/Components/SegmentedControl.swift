import SwiftUI

/// A palette-aware segmented control that grows with Dynamic Type (R7-4, R7-5, R7-23, plan 024 Task 11).
///
/// The stock `.pickerStyle(.segmented)` draws a cool grey `#2C2A2A` track with a `#656467` pill in dark mode and keeps
/// 13 pt titles at every text size. This one draws a `quietFill` track with a raised `selectedSegment` pill and a
/// hairline, titles at 13.5 pt that scale with Dynamic Type, every segment a 44 pt target, and — when the titles no
/// longer fit side by side (an accessibility size, or a long title) — the same options as a vertical list with a check
/// on the chosen one, instead of truncating.
///
/// ```swift
/// ChirpSegmentedControl("View", selection: $tab, segments: [
///     .init("Notes", value: .notes), .init("Live transcript", value: .transcript),
/// ], width: .fill)
/// ChirpSegmentedControl("Engine", selection: $engine, segments: [
///     .init("Needle", value: .needle, isEnabled: isNeedleReady), .init("Rules (basic)", value: .stub),
/// ])
/// ```
///
/// VoiceOver reads each segment as a button with "Selected" on the chosen one, inside a container named `label`.
public struct ChirpSegmentedControl<Value: Hashable>: View {
    /// One option.
    public struct Segment: Identifiable {
        public let title: String
        public let value: Value
        /// A symbol shown before the title (or alone, with the title as its VoiceOver label, when `iconOnly`).
        public let systemImage: String?
        public let iconOnly: Bool
        /// A disabled segment stays visible and legible (a `secondary` italic title) but cannot be chosen; VoiceOver
        /// reads it as dimmed. Say why next to the control.
        public let isEnabled: Bool

        public var id: Value { value }

        public init(
            _ title: String, value: Value, systemImage: String? = nil, iconOnly: Bool = false, isEnabled: Bool = true
        ) {
            self.title = title
            self.value = value
            self.systemImage = systemImage
            self.iconOnly = iconOnly && systemImage != nil
            self.isEnabled = isEnabled
        }
    }

    /// How wide the control is.
    public enum Width: Sendable {
        /// As wide as its titles (a trailing control in a settings row).
        case fit
        /// The full width offered, segments sharing it equally (a control above content).
        case fill
    }

    private let label: String
    @Binding private var selection: Value
    private let segments: [Segment]
    private let width: Width

    @ScaledMetric(relativeTo: .subheadline) private var titleSize: CGFloat = 13.5
    @ScaledMetric(relativeTo: .subheadline) private var pillHeight: CGFloat = Tokens.Metric.compactButtonHeight

    public init(_ label: String, selection: Binding<Value>, segments: [Segment], width: Width = .fit) {
        self.label = label
        _selection = selection
        self.segments = segments
        self.width = width
    }

    /// Track inset around the pills.
    private static var inset: CGFloat { 2 }

    /// Extra room above and below the track so every segment is a 44 pt target while the track keeps its size.
    private var targetPadding: CGFloat {
        max(0, (Tokens.Metric.minTapTarget - pillHeight - 2 * Self.inset) / 2)
    }

    public var body: some View {
        ViewThatFits(in: .horizontal) {
            row
            column
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }

    // MARK: Side by side

    private var row: some View {
        HStack(spacing: 0) {
            ForEach(segments) { segment in
                Button {
                    selection = segment.value
                } label: {
                    title(of: segment)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, Tokens.Spacing.s)
                        .frame(maxWidth: width == .fill ? .infinity : nil, minHeight: pillHeight)
                        .background { pill(isSelected: segment.value == selection) }
                        .padding(Self.inset)
                        .padding(.vertical, targetPadding)
                        .contentShape(Rectangle())
                }
                .buttonStyle(ChirpUndimmedButtonStyle())
                .disabled(!segment.isEnabled)
                .modifier(SegmentAccessibility(segment: segment, isSelected: segment.value == selection))
            }
        }
        .background {
            RoundedRectangle(cornerRadius: Tokens.Radius.track, style: .continuous)
                .fill(Tokens.Color.quietFill)
                .padding(.vertical, targetPadding)
        }
        .frame(maxWidth: width == .fill ? .infinity : nil)
    }

    // MARK: Stacked (the titles no longer fit side by side)

    private var column: some View {
        VStack(spacing: 0) {
            ForEach(segments) { segment in
                let isSelected = segment.value == selection
                Button {
                    selection = segment.value
                } label: {
                    HStack(spacing: Tokens.Spacing.xs) {
                        title(of: segment, iconOnly: false)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: Tokens.Spacing.xs)
                        Image(systemName: "checkmark")
                            .chirpGlyph(13.5, .bold)
                            .foregroundStyle(Tokens.Color.ink)
                            .opacity(isSelected ? 1 : 0)
                            .accessibilityHidden(true)
                    }
                    .padding(.horizontal, Tokens.Spacing.s)
                    .padding(.vertical, Tokens.Spacing.xs)
                    .frame(maxWidth: .infinity, minHeight: Tokens.Metric.minTapTarget, alignment: .leading)
                    .background { pill(isSelected: isSelected) }
                    .padding(Self.inset)
                    .contentShape(Rectangle())
                }
                .buttonStyle(ChirpUndimmedButtonStyle())
                .disabled(!segment.isEnabled)
                .modifier(SegmentAccessibility(segment: segment, isSelected: isSelected))
            }
        }
        .background(
            RoundedRectangle(cornerRadius: Tokens.Radius.track, style: .continuous).fill(Tokens.Color.quietFill))
    }

    // MARK: Pieces

    @ViewBuilder private func title(of segment: Segment, iconOnly: Bool? = nil) -> some View {
        let isSelected = segment.value == selection
        // Disabled reads `secondary` in italics, not `mutedText` (2.79:1 on the light track): still legible.
        let ink: Color = isSelected && segment.isEnabled ? Tokens.Color.ink : Tokens.Color.secondary
        Group {
            if let systemImage = segment.systemImage, iconOnly ?? segment.iconOnly {
                Image(systemName: systemImage)
                    .chirpGlyph(15, .semibold, relativeTo: .subheadline)
            } else if let systemImage = segment.systemImage {
                Label(segment.title, systemImage: systemImage)
                    .font(.system(size: titleSize, weight: .semibold))
            } else {
                Text(segment.title)
                    .font(.system(size: titleSize, weight: .semibold))
            }
        }
        .italic(!segment.isEnabled)
        .foregroundStyle(ink)
    }

    @ViewBuilder private func pill(isSelected: Bool) -> some View {
        if isSelected {
            RoundedRectangle(cornerRadius: Tokens.Radius.xs, style: .continuous)
                .fill(Tokens.Color.selectedSegment)
                .overlay(
                    RoundedRectangle(cornerRadius: Tokens.Radius.xs, style: .continuous)
                        .strokeBorder(Tokens.Color.border, lineWidth: Tokens.Metric.hairline)
                )
                .shadow(
                    color: Tokens.Color.raisedShadow, radius: Tokens.Metric.raisedShadowRadius,
                    y: Tokens.Metric.raisedShadowY)
        }
    }
}

private struct SegmentAccessibility<Value: Hashable>: ViewModifier {
    let segment: ChirpSegmentedControl<Value>.Segment
    let isSelected: Bool

    func body(content: Content) -> some View {
        content
            .accessibilityLabel(segment.title)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

#Preview("ChirpSegmentedControl") {
    @Previewable @State var tab = 0
    @Previewable @State var mode = "raw"
    @Previewable @State var layout = "list"
    VStack(alignment: .leading, spacing: Tokens.Spacing.m) {
        ChirpSegmentedControl(
            "View", selection: $tab, segments: [.init("Notes", value: 0), .init("Live transcript", value: 1)],
            width: .fill)
        ChirpSegmentedControl(
            "Clean-up", selection: $mode, segments: [.init("Raw", value: "raw"), .init("Clean", value: "clean")])
        ChirpSegmentedControl(
            "Engine", selection: $mode,
            segments: [.init("Needle", value: "needle", isEnabled: false), .init("Rules (basic)", value: "raw")])
        ChirpSegmentedControl(
            "Layout", selection: $layout,
            segments: [
                .init("Grid layout", value: "grid", systemImage: "square.grid.2x2", iconOnly: true),
                .init("List layout", value: "list", systemImage: "list.bullet", iconOnly: true),
            ])
    }
    .padding(Tokens.Spacing.xl)
    .background(Tokens.Color.ground)
}
