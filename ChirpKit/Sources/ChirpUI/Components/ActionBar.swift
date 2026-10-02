import SwiftUI

// The bottom bars (R7-12, R6b-18, plan 024 Task 11). Before this file the app drew its bottom chrome six ways: opaque
// `ground` in Create, Create's run and Edit by voice; `ground` at 94% in Transcript, Document and the Transform run;
// at 96% in Ask; with three private copies of the icon-over-label item that shrank "Transform" by different rules.
//
// Ruling: one opaque `ground` bar with a `border` hairline on top. Opaque, not translucent or glass, so every label
// on it is measured by `ContrastTests` (ink and accentInk on ground) whatever scrolls underneath.

extension View {
    /// The bottom bars' chrome: opaque `ground`, a hairline on top, extending under the home indicator.
    public func chirpBarBackground() -> some View {
        background(
            Tokens.Color.ground
                .overlay(alignment: .top) {
                    Rectangle().fill(Tokens.Color.border).frame(height: Tokens.Metric.hairline)
                }
                .ignoresSafeArea(edges: .bottom)
        )
    }
}

/// A sheet's bottom bar of buttons (Create's start bar, Create's run, Edit by voice): the shared chrome around any
/// content, padded by the sheet gutter. Put `ChirpButtonStyle` buttons in it.
///
/// ```swift
/// .safeAreaInset(edge: .bottom, spacing: 0) {
///     ChirpBottomBar {
///         HStack(spacing: Tokens.Spacing.s) {
///             Button("Create another") { … }.buttonStyle(.chirpSecondary)
///             Button("Done") { … }.buttonStyle(.chirpPrimary)
///         }
///     }
/// }
/// ```
public struct ChirpBottomBar<Content: View>: View {
    private let content: Content
    private let horizontalPadding: CGFloat

    public init(horizontalPadding: CGFloat = Tokens.Spacing.sheetGutter, @ViewBuilder content: () -> Content) {
        self.content = content()
        self.horizontalPadding = horizontalPadding
    }

    public var body: some View {
        content
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, Tokens.Spacing.xs)
            .frame(maxWidth: .infinity)
            .chirpBarBackground()
    }
}

/// A screen's bottom action bar of icon-over-label items (Transcript, Document, the Transform run): Copy, Share,
/// Listen, Transform. Items share the width equally in one row; when any label no longer fits its share (an
/// accessibility text size), the bar becomes two columns (a 2 × 2 grid for four items), then one — labels never
/// shrink or truncate.
///
/// ```swift
/// ChirpActionBar {
///     ChirpActionBarItem(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") { copy() }
///     Menu { … } label: { ChirpActionBarLabel("Share", systemImage: "square.and.arrow.up") }
///     ChirpActionBarItem("Transform", systemImage: "sparkles", emphasized: true) { transform() }
/// }
/// ```
public struct ChirpActionBar<Content: View>: View {
    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        ChirpActionBarLayout { content }
            .frame(maxWidth: .infinity)
            .chirpBarBackground()
    }
}

/// One action-bar button: `ChirpActionBarLabel` in a plain button.
public struct ChirpActionBarItem: View {
    private let title: String
    private let systemImage: String
    private let emphasized: Bool
    private let action: () -> Void

    public init(_ title: String, systemImage: String, emphasized: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.emphasized = emphasized
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            ChirpActionBarLabel(title, systemImage: systemImage, emphasized: emphasized)
        }
        .buttonStyle(.plain)
    }
}

/// The icon-over-label look of an action-bar item, for a `Menu` label or an app-side button (Listen) in the bar.
/// The glyph grows with Dynamic Type up to 1.6× (R7-4); the label is one line at every size because the bar
/// re-flows instead (see `ChirpActionBar`). A long press shows the large content viewer.
public struct ChirpActionBarLabel: View {
    private let title: String
    private let systemImage: String
    private let emphasized: Bool

    @ScaledMetric(relativeTo: .caption) private var glyphBox: CGFloat = 22
    @ScaledMetric(relativeTo: .caption) private var titleSize: CGFloat = 11

    public init(_ title: String, systemImage: String, emphasized: Bool = false) {
        self.title = title
        self.systemImage = systemImage
        self.emphasized = emphasized
    }

    public var body: some View {
        VStack(spacing: Tokens.Spacing.xxs) {
            Image(systemName: systemImage)
                .chirpGlyph(19, .medium, relativeTo: .caption, maxScale: 1.6)
                // One icon box for every item, so the labels share a baseline (UX audit F40).
                .frame(height: Tokens.Scale.capped(glyphBox, base: 22, maxScale: 1.6))
                .accessibilityHidden(true)  // the title names the action; the button or menu around it adds the trait
            Text(title)
                .font(.system(size: titleSize, weight: emphasized ? .bold : .semibold))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .foregroundStyle(emphasized ? Tokens.Color.accentInk : Tokens.Color.ink)
        .padding(.horizontal, Tokens.Spacing.xxs)
        .padding(.vertical, Tokens.Spacing.xs)
        .frame(maxWidth: .infinity, minHeight: Tokens.Metric.actionBarHeight)
        .contentShape(Rectangle())
        .accessibilityShowsLargeContentViewer {
            Label(title, systemImage: systemImage)
        }
    }
}

/// Lays out an action bar's items: one row of equal columns when every item's one-line width fits its share, else
/// two columns, else one. Rows are as tall as their tallest item.
public struct ChirpActionBarLayout: Layout {
    public init() {}

    /// The number of columns for items of these ideal widths in `available` points: all in one row when the widest
    /// fits an equal share, else two columns (for three or more items), else one.
    public static func columnCount(itemWidths: [CGFloat], available: CGFloat) -> Int {
        guard !itemWidths.isEmpty, available > 0 else { return 1 }
        let widest = itemWidths.max() ?? 0
        var candidates = [itemWidths.count]
        if itemWidths.count > 2 { candidates.append(2) }
        for columns in candidates where widest <= available / CGFloat(columns) + 0.5 {
            return columns
        }
        return 1
    }

    /// Rows needed for `items` in `columns` columns.
    public static func rowCount(items: Int, columns: Int) -> Int {
        guard items > 0, columns > 0 else { return 0 }
        return (items + columns - 1) / columns
    }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? subviews.reduce(0) { $0 + $1.sizeThatFits(.unspecified).width }
        let columns = columns(for: subviews, width: width)
        let height = rowHeights(for: subviews, columns: columns, width: width).reduce(0, +)
        return CGSize(width: width, height: height)
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let columns = columns(for: subviews, width: bounds.width)
        let columnWidth = bounds.width / CGFloat(columns)
        let heights = rowHeights(for: subviews, columns: columns, width: bounds.width)
        var y = bounds.minY
        for (row, height) in heights.enumerated() {
            for column in 0..<columns {
                let index = row * columns + column
                guard index < subviews.count else { break }
                subviews[index].place(
                    at: CGPoint(x: bounds.minX + CGFloat(column) * columnWidth, y: y), anchor: .topLeading,
                    proposal: ProposedViewSize(width: columnWidth, height: height))
            }
            y += height
        }
    }

    private func columns(for subviews: Subviews, width: CGFloat) -> Int {
        Self.columnCount(itemWidths: subviews.map { $0.sizeThatFits(.unspecified).width }, available: width)
    }

    private func rowHeights(for subviews: Subviews, columns: Int, width: CGFloat) -> [CGFloat] {
        let columnWidth = width / CGFloat(columns)
        return (0..<Self.rowCount(items: subviews.count, columns: columns)).map { row in
            (0..<columns).compactMap { column -> CGFloat? in
                let index = row * columns + column
                guard index < subviews.count else { return nil }
                return subviews[index].sizeThatFits(ProposedViewSize(width: columnWidth, height: nil)).height
            }.max() ?? 0
        }
    }
}

#Preview("ChirpActionBar") {
    VStack(spacing: 0) {
        Spacer()
        ChirpActionBar {
            ChirpActionBarItem("Copy", systemImage: "doc.on.doc") {}
            ChirpActionBarItem("Share", systemImage: "square.and.arrow.up") {}
            ChirpActionBarItem("Listen", systemImage: "speaker.wave.2") {}
            ChirpActionBarItem("Transform", systemImage: "sparkles", emphasized: true) {}
        }
        ChirpBottomBar {
            HStack(spacing: Tokens.Spacing.s) {
                Button("Create another") {}.buttonStyle(.chirpSecondary)
                Button("Done") {}.buttonStyle(.chirpPrimary)
            }
        }
    }
    .background(Tokens.Color.ground)
}
