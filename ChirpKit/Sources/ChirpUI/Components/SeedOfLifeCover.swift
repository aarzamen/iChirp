import SwiftUI

/// The night-field "Seed of Life" cover used for meeting rows in Capture's Recent list and in
/// Library (`docs/design/2026-09-21-iphone-canvas/Home.dc.html`,
/// `docs/design/2026-09-21-iphone-canvas/Library.dc.html`): seven overlapping circles on
/// `Tokens.Color.coverNight`, rotated, with one or two circles picked out in a brighter stroke.
///
/// Sized entirely by whatever frame the caller gives it — clip it to a radius with
/// `.clipShape` if you want rounded corners (Library/Capture rows use `Tokens.Radius.cover` /
/// `.coverSmall`).
public struct SeedOfLifeCover: View {
    /// Any stable identifier for the transcript this cover represents (e.g. a row id hashed to
    /// an `Int`, or the transcript's index). Drives which circles are highlighted and how far
    /// the ring is rotated, so two different meetings don't render identical covers.
    public var seed: Int

    public init(seed: Int) {
        self.seed = seed
    }

    public var body: some View {
        GeometryReader { proxy in
            ZStack {
                Tokens.Color.coverNight
                circles(in: proxy.size)
                    .rotationEffect(.degrees(rotationDegrees))
            }
        }
        .accessibilityHidden(true)  // Decorative; the row it sits in carries its own label.
    }

    // MARK: Geometry

    /// The seven circle centers of a Seed-of-Life rosette, normalized to a unit square,
    /// matching the canvas's `viewBox="0 0 100 100"` covers (center, then six around it).
    private static let normalizedCenters: [CGPoint] = [
        CGPoint(x: 0.50, y: 0.50),
        CGPoint(x: 0.50, y: 0.32),
        CGPoint(x: 0.656, y: 0.41),
        CGPoint(x: 0.656, y: 0.59),
        CGPoint(x: 0.50, y: 0.68),
        CGPoint(x: 0.344, y: 0.59),
        CGPoint(x: 0.344, y: 0.41),
    ]
    private static let normalizedRadius: CGFloat = 0.18

    /// A handful of rotation angles pulled from the canvas artboards (16°, -9°, …), cycled by
    /// `seed` so covers read as visually distinct without needing true randomness.
    private static let rotationSteps: [Double] = [16, -9, 24, -20, 9, -16, 20, -24]

    private var rotationDegrees: Double {
        Self.rotationSteps[Self.nonNegative(seed) % Self.rotationSteps.count]
    }

    /// One or two highlighted circles, mirroring the canvas (Capture's Recent row highlights
    /// one; Library's "Today" row highlights two).
    private var highlightedIndices: Set<Int> {
        let index = Self.nonNegative(seed)
        let highlightCount = (index % 2) + 1
        let first = (index % (Self.normalizedCenters.count - 1)) + 1  // skip the center circle
        var indices: Set<Int> = [first]
        if highlightCount == 2 {
            indices.insert(((first - 1 + 3) % (Self.normalizedCenters.count - 1)) + 1)
        }
        return indices
    }

    private static func nonNegative(_ value: Int) -> Int {
        value == Int.min ? 0 : abs(value)
    }

    private func circles(in size: CGSize) -> some View {
        let diameter = Self.normalizedRadius * 2 * min(size.width, size.height)
        return ZStack {
            ForEach(Array(Self.normalizedCenters.enumerated()), id: \.offset) { index, center in
                let highlighted = highlightedIndices.contains(index)
                Circle()
                    .stroke(
                        highlighted ? Tokens.Color.seedStrokeBright : Tokens.Color.seedStrokeDim.opacity(0.5),
                        lineWidth: highlighted ? 2 : 1.7
                    )
                    .frame(width: diameter, height: diameter)
                    .position(x: center.x * size.width, y: center.y * size.height)
            }
        }
        .frame(width: size.width, height: size.height)
    }
}

#Preview("SeedOfLifeCover") {
    HStack(spacing: 12) {
        ForEach(0..<4) { seed in
            SeedOfLifeCover(seed: seed)
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.cover, style: .continuous))
        }
    }
    .padding(24)
    .background(Tokens.Color.ground)
}
