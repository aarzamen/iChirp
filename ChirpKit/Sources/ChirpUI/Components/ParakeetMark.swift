import SwiftUI

/// The Parakeet logo mark, converted from the coral SVG path in the design canvas
/// (`docs/design/2026-09-21-iphone-canvas/Home.dc.html`, `viewBox 0 0 1024 1024`).
///
/// The silhouette's negative space (the head/wing carve-outs) relies on the source path's
/// `fill-rule="evenodd"`, so draw it with `.fill(color, style: FillStyle(eoFill: true))` —
/// or just use `ParakeetMarkView`, which does that for you.
public struct ParakeetMark: Shape {
    public init() {}

    public func path(in rect: CGRect) -> Path {
        let scale = CGAffineTransform(
            scaleX: rect.width / Self.viewBoxSize.width, y: rect.height / Self.viewBoxSize.height)
        let transform = scale.concatenating(CGAffineTransform(translationX: rect.minX, y: rect.minY))

        var combined = Path()
        for data in Self.svgPathData {
            combined.addPath(SVGPathParser.path(fromData: data), transform: transform)
        }
        return combined
    }

    private static let viewBoxSize = CGSize(width: 1024, height: 1024)

    /// The four `<path d="…">` strings from the canvas SVG, verbatim.
    private static let svgPathData: [String] = [
        // Main silhouette (source fill-rule: evenodd — carves the head/wing negative space).
        "M 532.0 246.9 c -11.7 2.6 -16.9 4.5 -28.0 10.2 -21.6 11.0 -38.3 28.6 -50.8 53.5 -17.2 34.4 -23.8 75.8 -29.2 183.4 -1.1 22.3 -2.5 46.1 -3.0 53.0 -1.4 17.2 -6.1 55.3 -6.9 56.2 -0.3 0.4 -7.1 1.6 -15.1 2.8 -40.0 5.9 -68.5 16.2 -88.1 31.8 -13.7 10.9 -22.8 25.6 -25.0 40.4 -3.5 22.0 7.0 42.4 26.5 51.8 29.0 13.9 63.2 6.6 88.6 -19.0 17.6 -17.6 31.3 -44.2 41.9 -81.5 l 2.9 -10.0 13.3 -1.2 c 7.4 -0.6 19.3 -1.7 26.4 -2.3 64.1 -5.7 100.5 -19.6 130.1 -49.4 21.8 -21.9 36.3 -50.7 40.6 -80.2 1.6 -11.3 1.6 -37.7 0.0 -47.4 -1.4 -8.6 -5.4 -21.5 -8.4 -27.4 l -2.0 -4.0 -1.6 3.0 c -4.3 8.2 -17.7 23.1 -25.7 28.5 l -3.5 2.4 0.0 13.4 c 0.0 29.8 -10.0 59.0 -27.8 81.3 -6.9 8.6 -20.3 21.4 -28.5 27.3 -17.5 12.3 -47.6 24.0 -74.6 28.9 -16.8 3.1 -32.9 5.2 -33.6 4.4 -0.3 -0.3 0.6 -9.1 2.0 -19.6 3.4 -25.9 5.8 -52.5 9.4 -104.7 3.7 -53.4 5.4 -70.8 8.7 -88.5 7.7 -41.7 17.9 -65.8 36.0 -85.0 20.1 -21.2 48.5 -30.5 74.0 -24.0 25.9 6.6 43.4 24.3 49.5 49.8 2.8 11.6 2.3 31.1 -1.1 41.7 -9.0 28.4 -28.5 47.9 -56.2 56.4 -20.1 6.1 -48.3 4.4 -65.3 -3.9 -3.3 -1.6 -6.2 -2.7 -6.4 -2.4 -1.0 1.0 14.8 15.0 21.0 18.7 33.2 19.5 79.5 11.4 107.7 -18.8 7.9 -8.4 11.5 -13.7 16.7 -24.8 5.4 -11.5 8.2 -21.9 9.5 -36.0 1.8 -18.8 -1.0 -38.5 -7.4 -53.1 -9.0 -20.3 -28.4 -39.4 -49.1 -48.3 -15.5 -6.7 -23.1 -8.3 -42.5 -8.8 -13.7 -0.4 -17.9 -0.2 -25.0 1.4 z m -122.0 375.3 c 0.0 0.7 -1.3 6.4 -3.0 12.5 -10.2 39.0 -29.5 64.8 -55.1 73.9 -17.0 5.9 -37.5 2.5 -46.3 -7.8 -9.5 -11.1 -5.7 -30.7 8.9 -45.2 10.4 -10.4 24.5 -18.4 43.5 -24.6 13.0 -4.3 18.4 -5.5 35.5 -8.0 15.0 -2.2 16.5 -2.3 16.5 -0.8 z",
        // Eye.
        "M 582.0 313.8 c -10.7 5.3 -10.7 20.4 0.1 26.0 10.1 5.3 21.0 -1.7 21.2 -13.5 0.1 -10.4 -11.7 -17.4 -21.3 -12.5 z",
        // Head accent stroke.
        "M 659.7 327.7 c 1.0 4.7 1.3 11.2 1.1 21.0 l -0.3 14.1 4.6 0.6 c 7.5 1.0 15.9 8.4 15.9 14.1 0.0 3.1 1.9 1.4 4.7 -4.3 2.5 -5.0 2.8 -6.8 2.8 -15.2 0.0 -8.1 -0.4 -10.3 -2.6 -15.0 -4.5 -9.5 -14.5 -17.9 -25.5 -21.4 -2.2 -0.7 -2.2 -0.6 -0.7 6.1 z",
        // Tail feather.
        "M 469.1 623.9 l -6.4 0.6 -3.2 9.5 c -10.2 30.6 -29.7 63.4 -51.4 86.4 l -5.6 5.9 5.5 -2.8 c 29.1 -14.5 56.2 -47.0 75.5 -90.5 l 4.4 -10.0 -6.2 0.2 c -3.4 0.1 -9.1 0.4 -12.6 0.7 z",
    ]
}

/// A ready-to-drop-in coral Parakeet mark, filled with the evenodd rule the source path needs.
///
/// Decorative by default (hidden from VoiceOver), since most uses sit next to a "Parakeet"
/// text label that already announces it. Where the mark stands alone as a logo, pass
/// `accessibilityLabel` (e.g. `"Parakeet"`) so it's announced.
public struct ParakeetMarkView: View {
    public var color: Color
    public var accessibilityLabel: String?

    public init(color: Color = Tokens.Color.accent, accessibilityLabel: String? = nil) {
        self.color = color
        self.accessibilityLabel = accessibilityLabel
    }

    public var body: some View {
        let mark = ParakeetMark().fill(color, style: FillStyle(eoFill: true))
        if let accessibilityLabel {
            mark.accessibilityLabel(accessibilityLabel)
        } else {
            mark.accessibilityHidden(true)
        }
    }
}

/// Minimal SVG path-data parser supporting the commands ChirpUI's vector marks use: absolute
/// and relative moveto (`M`/`m`), lineto (`L`/`l`), horizontal/vertical lineto (`H`/`h`,
/// `V`/`v`), cubic curveto (`C`/`c`) and closepath (`Z`/`z`). Implicit repeated argument sets
/// (e.g. `"L x y x y"`, as this path data uses after `c` and `l`) continue the previous
/// command, exactly as the SVG path grammar requires.
private enum SVGPathParser {
    private enum Token {
        case command(Character)
        case number(CGFloat)
    }

    static func path(fromData data: String) -> Path {
        var path = Path()
        let tokens = tokenize(data)
        var index = 0
        var current = CGPoint.zero
        var subpathStart = CGPoint.zero
        var command: Character = "M"

        func number() -> CGFloat {
            guard index < tokens.count, case let .number(value) = tokens[index] else {
                assertionFailure("SVGPathParser: expected a number at token \(index) in \"\(data)\"")
                return 0
            }
            index += 1
            return value
        }

        func point(isRelative: Bool) -> CGPoint {
            let x = number()
            let y = number()
            return isRelative ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
        }

        while index < tokens.count {
            if case let .command(letter) = tokens[index] {
                command = letter
                index += 1
            }
            switch command {
            case "M", "m":
                let next = point(isRelative: command == "m")
                path.move(to: next)
                current = next
                subpathStart = next
                // Subsequent coordinate pairs after M/m are an implicit lineto.
                command = command == "m" ? "l" : "L"
            case "L", "l":
                let next = point(isRelative: command == "l")
                path.addLine(to: next)
                current = next
            case "H", "h":
                let x = number()
                let next = CGPoint(x: command == "h" ? current.x + x : x, y: current.y)
                path.addLine(to: next)
                current = next
            case "V", "v":
                let y = number()
                let next = CGPoint(x: current.x, y: command == "v" ? current.y + y : y)
                path.addLine(to: next)
                current = next
            case "C", "c":
                let isRelative = command == "c"
                let control1 = point(isRelative: isRelative)
                let control2 = point(isRelative: isRelative)
                let end = point(isRelative: isRelative)
                path.addCurve(to: end, control1: control1, control2: control2)
                current = end
            case "Z", "z":
                path.closeSubpath()
                current = subpathStart
            default:
                index += 1
            }
        }
        return path
    }

    /// Splits `data` into command letters and numbers. Handles commas or whitespace as
    /// separators, and also a bare `-` starting a new number with no separator before it (the
    /// common SVG-export shorthand for a negative coordinate directly after a positive one).
    private static func tokenize(_ data: String) -> [Token] {
        var tokens: [Token] = []
        var numberScalars = ""

        func flushNumber() {
            guard !numberScalars.isEmpty else { return }
            if let value = Double(numberScalars) {
                tokens.append(.number(CGFloat(value)))
            }
            numberScalars = ""
        }

        for scalar in data.unicodeScalars {
            let char = Character(scalar)
            switch char {
            case "M", "m", "L", "l", "H", "h", "V", "v", "C", "c", "Z", "z":
                flushNumber()
                tokens.append(.command(char))
            case "0"..."9", ".":
                numberScalars.append(char)
            case "-":
                flushNumber()  // "-" always starts a new number, even mid-run.
                numberScalars.append(char)
            case " ", ",", "\n", "\t":
                flushNumber()
            default:
                // A letter here is an SVG path command this parser doesn't implement (e.g. the
                // S/Q/T/A shorthand-curve and arc commands) — fail loudly in debug builds
                // instead of silently dropping it and producing a mangled shape. Any other
                // stray character (unexpected whitespace variants, etc.) is ignored.
                if char.isLetter {
                    assertionFailure("SVGPathParser: unsupported command \"\(char)\" in \"\(data)\"")
                }
            }
        }
        flushNumber()
        return tokens
    }
}

#Preview("ParakeetMark") {
    HStack(spacing: 24) {
        ParakeetMarkView()
            .frame(width: 27, height: 27)
        ParakeetMarkView()
            .frame(width: 76, height: 76)
        ParakeetMarkView(color: .white)
            .frame(width: 76, height: 76)
    }
    .padding(32)
    .background(Tokens.Color.tint)
}
