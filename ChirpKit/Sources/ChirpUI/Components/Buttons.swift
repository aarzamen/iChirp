import SwiftUI

/// The one capsule button (R6a-15, R6b-18, plan 024 Task 11): one height, one font, one shape for every primary,
/// secondary and compact action, instead of the seven hand-rolled variants (44–54 pt, 14–17 pt, rounded rectangles and
/// capsules, `.white` labels on `accentFill` or on the 3.2:1 `mutedText` when disabled).
///
/// ```swift
/// Button("Create") { start() }.buttonStyle(.chirpPrimary)                      // full-width coral capsule
/// Button("Create another") { … }.buttonStyle(.chirpSecondary)                  // full-width tint capsule
/// Button("Stop & save") { … }.buttonStyle(.chirp(.stop))                       // full-width red capsule
/// Button("Retry") { … }.buttonStyle(.chirp(.tinted, size: .compact))           // 32 pt pill in a 44 pt target
/// ```
///
/// - `.large`: fills the width it is offered, at least `Tokens.Metric.primaryButtonHeight` (50 pt) tall, a 16 pt bold
///   label. It grows with its text at larger sizes and wraps to two lines rather than truncating.
/// - `.compact`: hugs its label; a `Tokens.Metric.compactButtonHeight` (32 pt) pill with a 13.5 pt bold label inside a
///   44 pt tap target (the frame is inside the label, so the target really is 44 pt).
///
/// Every label/fill pair is in `ContrastTests`. A disabled button (`.disabled(true)`) is a quiet capsule with a
/// `secondary` label (4.65:1), not a grey fill with a white label; say why it cannot start in text beside it.
public struct ChirpButtonStyle: ButtonStyle {
    public enum Kind: CaseIterable, Sendable {
        /// The one primary action: `accentFill` with an `onAccent` label (Create, Done, Start, Transcribe).
        case filled
        /// A secondary action: `tint` with an `accentInkPressed` label (Create another, Versions, Cancel import).
        case tinted
        /// A neutral action: `quietFill` with a `secondary` label.
        case quiet
        /// A destructive action that is not the main one: `quietFill` with an `errorInk` label (Stop a run).
        case destructive
        /// A destructive main action: `stopRed` with an `onAccent` label (Stop & save).
        case stop
    }

    public enum Size: CaseIterable, Sendable {
        /// Full width, 50 pt, 16 pt bold.
        case large
        /// A 32 pt pill that hugs its label, 13.5 pt bold, in a 44 pt target.
        case compact
    }

    public var kind: Kind
    public var size: Size

    public init(_ kind: Kind = .filled, size: Size = .large) {
        self.kind = kind
        self.size = size
    }

    public func makeBody(configuration: Configuration) -> some View {
        ChirpButtonBody(label: configuration.label, isPressed: configuration.isPressed, kind: kind, size: size)
    }
}

extension ButtonStyle where Self == ChirpButtonStyle {
    /// The full-width coral capsule: the screen's one primary action.
    public static var chirpPrimary: ChirpButtonStyle { ChirpButtonStyle(.filled) }
    /// The full-width tint capsule beside or instead of a primary action.
    public static var chirpSecondary: ChirpButtonStyle { ChirpButtonStyle(.tinted) }
    /// Any kind, at either size.
    public static func chirp(_ kind: ChirpButtonStyle.Kind, size: ChirpButtonStyle.Size = .large) -> ChirpButtonStyle {
        ChirpButtonStyle(kind, size: size)
    }
}

/// The label colors of each kind, shared with the tests' contrast table (`ContrastTests` measures every pair).
extension ChirpButtonStyle.Kind {
    /// The capsule's fill, enabled or not.
    public func fill(isEnabled: Bool) -> Color {
        guard isEnabled else { return Tokens.Color.quietFill }
        return switch self {
        case .filled: Tokens.Color.accentFill
        case .tinted: Tokens.Color.tint
        case .quiet, .destructive: Tokens.Color.quietFill
        case .stop: Tokens.Color.stopRed
        }
    }

    /// The label's color on `fill(isEnabled:)`.
    public func ink(isEnabled: Bool) -> Color {
        guard isEnabled else { return Tokens.Color.secondary }
        return switch self {
        case .filled, .stop: Tokens.Color.onAccent
        // F8: on `tint`, `accentInkPressed` (about 7:1), not `accentInk` (4.39:1 in light mode).
        case .tinted: Tokens.Color.accentInkPressed
        case .quiet: Tokens.Color.secondary
        case .destructive: Tokens.Color.errorInk
        }
    }
}

/// Two or more `.large` buttons side by side (Create another · Done, Stop · Hide) that stack, full width, when their
/// labels no longer fit on one line each (an accessibility text size), instead of wrapping into capsules of uneven
/// height.
///
/// ```swift
/// ChirpButtonRow {
///     Button("Create another") { … }.buttonStyle(.chirpSecondary)
///     Button("Done") { … }.buttonStyle(.chirpPrimary)
/// }
/// ```
public struct ChirpButtonRow<Content: View>: View {
    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Tokens.Spacing.s) { content }
            VStack(spacing: Tokens.Spacing.s) { content }
        }
    }
}

/// A plain button style that does not dim a disabled label: ChirpUI's controls draw their own disabled look in
/// text-safe colors, and the system's dimming would push it below 4.5:1.
struct ChirpUndimmedButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}

private struct ChirpButtonBody<Label: View>: View {
    let label: Label
    let isPressed: Bool
    let kind: ChirpButtonStyle.Kind
    let size: ChirpButtonStyle.Size

    @Environment(\.isEnabled) private var isEnabled
    @ScaledMetric(relativeTo: .body) private var largeFont: CGFloat = 16
    @ScaledMetric(relativeTo: .subheadline) private var compactFont: CGFloat = 13.5

    var body: some View {
        styled
            .scaleEffect(isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: isPressed)
    }

    @ViewBuilder private var styled: some View {
        switch size {
        case .large:
            label
                .font(.system(size: largeFont, weight: .bold))
                .foregroundStyle(kind.ink(isEnabled: isEnabled))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .padding(.horizontal, Tokens.Spacing.m)
                .padding(.vertical, Tokens.Spacing.s)
                .frame(maxWidth: .infinity, minHeight: Tokens.Metric.primaryButtonHeight)
                .background(Capsule().fill(kind.fill(isEnabled: isEnabled)))
                .contentShape(Capsule())
        case .compact:
            label
                .font(.system(size: compactFont, weight: .bold))
                .foregroundStyle(kind.ink(isEnabled: isEnabled))
                .lineLimit(1)
                .padding(.horizontal, Tokens.Spacing.m)
                .padding(.vertical, Tokens.Spacing.xxs)
                .frame(minHeight: Tokens.Metric.compactButtonHeight)
                .background(Capsule().fill(kind.fill(isEnabled: isEnabled)))
                // The pill keeps its canvas size; the target grows to 44 pt inside the label (a frame added outside
                // a Button never widens its hit area, F7).
                .frame(minHeight: Tokens.Metric.minTapTarget)
                .contentShape(Rectangle())
        }
    }
}

#Preview("ChirpButtonStyle") {
    VStack(spacing: Tokens.Spacing.s) {
        Button {
        } label: {
            Label("Create", systemImage: "sparkles")
        }
        .buttonStyle(.chirpPrimary)
        Button("Create another") {}.buttonStyle(.chirpSecondary)
        Button("Stop & save") {}.buttonStyle(.chirp(.stop))
        Button("Stop") {}.buttonStyle(.chirp(.destructive))
        Button("Create") {}.buttonStyle(.chirpPrimary).disabled(true)
        HStack {
            Button("Retry") {}.buttonStyle(.chirp(.tinted, size: .compact))
            Button("Start") {}.buttonStyle(.chirp(.filled, size: .compact))
            Button("Delete") {}.buttonStyle(.chirp(.destructive, size: .compact))
        }
    }
    .padding(Tokens.Spacing.sheetGutter)
    .background(Tokens.Color.ground)
}
