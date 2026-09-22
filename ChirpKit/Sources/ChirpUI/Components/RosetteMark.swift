import SwiftUI

/// The green sacred-geometry rosette used for meeting capture
/// (`docs/design/2026-09-21-iphone-canvas/Home.dc.html`'s "Record Meeting" row and
/// `docs/design/2026-09-21-iphone-canvas/Meeting.dc.html`'s recording card): a seven-circle
/// Seed-of-Life flower with a stem and two leaves growing from it, from the canvas's
/// `viewBox="0 0 120 140"` artwork.
public struct RosetteMark: View {
    public var color: Color
    /// Draws the soft outer ring the Meeting recording card shows around the rosette while
    /// live.
    public var halo: Bool

    public init(color: Color = Tokens.Color.rosette, halo: Bool = false) {
        self.color = color
        self.halo = halo
    }

    public var body: some View {
        GeometryReader { proxy in
            let scale = min(proxy.size.width / Self.viewBoxSize.width, proxy.size.height / Self.viewBoxSize.height)
            let drawnSize = CGSize(width: Self.viewBoxSize.width * scale, height: Self.viewBoxSize.height * scale)
            let origin = CGPoint(
                x: (proxy.size.width - drawnSize.width) / 2, y: (proxy.size.height - drawnSize.height) / 2)
            let transform = CGAffineTransform(translationX: origin.x, y: origin.y).scaledBy(x: scale, y: scale)

            Canvas { context, _ in
                if halo {
                    let haloRect = CGRect(
                        x: Self.haloCenter.x - Self.haloRadius, y: Self.haloCenter.y - Self.haloRadius,
                        width: Self.haloRadius * 2, height: Self.haloRadius * 2)
                    context.stroke(
                        Path(ellipseIn: haloRect).applying(transform),
                        with: .color(Self.haloColor.opacity(0.45)),
                        lineWidth: 1.2 * scale
                    )
                }

                for center in Self.circleCenters {
                    let rect = CGRect(
                        x: center.x - Self.circleRadius, y: center.y - Self.circleRadius, width: Self.circleRadius * 2,
                        height: Self.circleRadius * 2)
                    context.stroke(
                        Path(ellipseIn: rect).applying(transform), with: .color(color), lineWidth: 2.2 * scale)
                }

                context.stroke(
                    Self.stemPath.applying(transform),
                    with: .color(color),
                    style: StrokeStyle(lineWidth: 2.6 * scale, lineCap: .round)
                )
                context.fill(Self.leafNearPath.applying(transform), with: .color(color.opacity(0.85)))
                context.fill(Self.leafFarPath.applying(transform), with: .color(color.opacity(0.55)))
            }
        }
        .aspectRatio(Self.viewBoxSize.width / Self.viewBoxSize.height, contentMode: .fit)
    }

    // MARK: Geometry (from the canvas's `viewBox="0 0 120 140"` SVG, verbatim coordinates)

    private static let viewBoxSize = CGSize(width: 120, height: 140)
    private static let circleRadius: CGFloat = 15
    private static let circleCenters: [CGPoint] = [
        CGPoint(x: 60, y: 48),
        CGPoint(x: 60, y: 33),
        CGPoint(x: 73, y: 40.5),
        CGPoint(x: 73, y: 55.5),
        CGPoint(x: 60, y: 63),
        CGPoint(x: 47, y: 55.5),
        CGPoint(x: 47, y: 40.5),
    ]

    private static let haloCenter = CGPoint(x: 60, y: 48)
    private static let haloRadius: CGFloat = 30
    private static let haloColor = SwiftUI.Color(red: 0.4, green: 0.851, blue: 0.4)  // #66D966

    private static let stemPath: Path = {
        var path = Path()
        path.move(to: CGPoint(x: 60, y: 63))
        path.addCurve(to: CGPoint(x: 60, y: 122), control1: CGPoint(x: 60, y: 86), control2: CGPoint(x: 58, y: 98))
        return path
    }()

    private static let leafNearPath: Path = {
        var path = Path()
        path.move(to: CGPoint(x: 60, y: 94))
        path.addCurve(to: CGPoint(x: 40, y: 76), control1: CGPoint(x: 48, y: 92), control2: CGPoint(x: 41, y: 84))
        path.addCurve(to: CGPoint(x: 60, y: 94), control1: CGPoint(x: 50, y: 76), control2: CGPoint(x: 58, y: 83))
        path.closeSubpath()
        return path
    }()

    private static let leafFarPath: Path = {
        var path = Path()
        path.move(to: CGPoint(x: 60, y: 108))
        path.addCurve(to: CGPoint(x: 80, y: 90), control1: CGPoint(x: 72, y: 106), control2: CGPoint(x: 79, y: 98))
        path.addCurve(to: CGPoint(x: 60, y: 108), control1: CGPoint(x: 70, y: 90), control2: CGPoint(x: 62, y: 97))
        path.closeSubpath()
        return path
    }()
}

#Preview("RosetteMark") {
    HStack(spacing: 24) {
        RosetteMark()
            .frame(width: 40, height: 47)
        RosetteMark(halo: true)
            .frame(width: 42, height: 49)
    }
    .padding(32)
    .background(Tokens.Color.surface)
}
