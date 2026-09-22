import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Centralized design tokens for MacParakeet on mobile (iOS).
/// Follows the "Warm Magical" design system — warm coral plumage accent,
/// generous touch targets, rounded typography, and tactile haptic feedback.
public enum MobileDesignSystem {

    // MARK: - Colors

    public enum Colors {
        // Accent — warm coral-orange
        public static let accent = Color(
            light: Color(red: 0.91, green: 0.42, blue: 0.23),
            dark: Color(red: 1.0, green: 0.54, blue: 0.36)
        )
        public static let accentLight = Color(
            light: Color(red: 1.0, green: 0.94, blue: 0.92),
            dark: Color(red: 1.0, green: 0.54, blue: 0.36).opacity(0.15)
        )
        public static let accentDark = Color(
            light: Color(red: 0.77, green: 0.33, blue: 0.16),
            dark: Color(red: 0.91, green: 0.42, blue: 0.23)
        )

        // Backgrounds
        public static let background = Color(
            light: Color(red: 0.98, green: 0.98, blue: 0.97),
            dark: Color(red: 0.08, green: 0.08, blue: 0.09)
        )
        public static let surface = Color(
            light: Color.white,
            dark: Color(red: 0.14, green: 0.14, blue: 0.15)
        )
        public static let surfaceElevated = Color(
            light: Color(red: 0.96, green: 0.96, blue: 0.94),
            dark: Color(red: 0.19, green: 0.19, blue: 0.20)
        )

        // Text
        public static let textPrimary = Color(
            light: Color(red: 0.10, green: 0.10, blue: 0.10),
            dark: Color.white
        )
        public static let textSecondary = Color(
            light: Color(red: 0.45, green: 0.45, blue: 0.47),
            dark: Color(red: 0.65, green: 0.65, blue: 0.68)
        )
        public static let textTertiary = Color(
            light: Color(red: 0.65, green: 0.65, blue: 0.68),
            dark: Color(red: 0.45, green: 0.45, blue: 0.48)
        )

        // Semantics
        public static let successGreen = Color(
            light: Color(red: 0.20, green: 0.66, blue: 0.33),
            dark: Color(red: 0.29, green: 0.87, blue: 0.50)
        )
        public static let warningAmber = Color(
            light: Color(red: 0.96, green: 0.65, blue: 0.14),
            dark: Color(red: 0.98, green: 0.75, blue: 0.14)
        )
        public static let errorRed = Color(
            light: Color(red: 0.90, green: 0.30, blue: 0.26),
            dark: Color(red: 0.97, green: 0.44, blue: 0.44)
        )

        // Borders & Dividers
        public static let border = Color(
            light: Color(red: 0.90, green: 0.90, blue: 0.88),
            dark: Color(red: 0.25, green: 0.25, blue: 0.27)
        )
        public static let divider = Color(
            light: Color(red: 0.93, green: 0.93, blue: 0.91),
            dark: Color(red: 0.20, green: 0.20, blue: 0.22)
        )

        // Speaker Diarization Palette
        public static let speakerColors: [Color] = [
            Color(light: Color(red: 0.20, green: 0.51, blue: 0.84), dark: Color(red: 0.42, green: 0.68, blue: 0.96)),
            Color(light: Color(red: 0.72, green: 0.33, blue: 0.64), dark: Color(red: 0.85, green: 0.52, blue: 0.78)),
            Color(light: Color(red: 0.16, green: 0.60, blue: 0.46), dark: Color(red: 0.30, green: 0.78, blue: 0.62)),
            Color(light: Color(red: 0.82, green: 0.52, blue: 0.14), dark: Color(red: 0.95, green: 0.68, blue: 0.30)),
            Color(light: Color(red: 0.80, green: 0.28, blue: 0.28), dark: Color(red: 0.95, green: 0.45, blue: 0.45)),
            Color(light: Color(red: 0.40, green: 0.56, blue: 0.24), dark: Color(red: 0.56, green: 0.76, blue: 0.38))
        ]

        public static func speakerColor(for index: Int) -> Color {
            speakerColors[abs(index) % speakerColors.count]
        }
    }

    // MARK: - Spacing

    public enum Spacing {
        public static let xs: CGFloat = 4
        public static let sm: CGFloat = 8
        public static let md: CGFloat = 16
        public static let lg: CGFloat = 24
        public static let xl: CGFloat = 32
        public static let xxl: CGFloat = 48
    }

    // MARK: - Typography

    public enum Typography {
        public static let hero = Font.system(size: 32, weight: .bold, design: .rounded)
        public static let title = Font.system(size: 22, weight: .bold, design: .rounded)
        public static let subtitle = Font.system(size: 17, weight: .semibold, design: .rounded)
        public static let headline = Font.system(size: 17, weight: .semibold)
        public static let subheadline = Font.system(size: 15, weight: .regular)
        public static let body = Font.system(size: 16)
        public static let bodySmall = Font.system(size: 14)
        public static let caption = Font.system(size: 12)
        public static let monoTimer = Font.system(size: 42, weight: .medium, design: .monospaced)
        public static let monoTimestamp = Font.system(size: 12, weight: .medium, design: .monospaced)
    }

    // MARK: - Corner Radii

    public enum CornerRadius {
        public static let sm: CGFloat = 8
        public static let md: CGFloat = 12
        public static let lg: CGFloat = 18
        public static let pill: CGFloat = 999
    }

    // MARK: - Haptics

    public enum Haptics {
        public static func light() {
            #if canImport(UIKit) && !os(macOS)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            #endif
        }

        public static func medium() {
            #if canImport(UIKit) && !os(macOS)
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            #endif
        }

        public static func heavy() {
            #if canImport(UIKit) && !os(macOS)
            UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
            #endif
        }

        public static func success() {
            #if canImport(UIKit) && !os(macOS)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            #endif
        }

        public static func error() {
            #if canImport(UIKit) && !os(macOS)
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            #endif
        }
    }
}

// MARK: - Color Light/Dark Helper

extension Color {
    public init(light: Color, dark: Color) {
        #if canImport(UIKit) && !os(macOS)
        self.init(uiColor: UIColor { trait in
            trait.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light)
        })
        #elseif os(macOS)
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return isDark ? NSColor(dark) : NSColor(light)
        })
        #else
        self = light
        #endif
    }
}

// MARK: - Action Button Styles

public struct MobileParakeetButtonStyle: ButtonStyle {
    public enum Variant {
        case primary
        case secondary
        case destructive
    }

    let variant: Variant

    public init(variant: Variant = .primary) {
        self.variant = variant
    }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(MobileDesignSystem.Typography.headline)
            .padding(.horizontal, MobileDesignSystem.Spacing.lg)
            .padding(.vertical, MobileDesignSystem.Spacing.md)
            .frame(maxWidth: .infinity)
            .background(backgroundColor(isPressed: configuration.isPressed))
            .foregroundColor(foregroundColor(isPressed: configuration.isPressed))
            .clipShape(RoundedRectangle(cornerRadius: MobileDesignSystem.CornerRadius.md, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: configuration.isPressed)
    }

    private func backgroundColor(isPressed: Bool) -> Color {
        switch variant {
        case .primary:
            return isPressed ? MobileDesignSystem.Colors.accentDark : MobileDesignSystem.Colors.accent
        case .secondary:
            return isPressed ? MobileDesignSystem.Colors.surfaceElevated : MobileDesignSystem.Colors.surface
        case .destructive:
            return isPressed ? MobileDesignSystem.Colors.errorRed.opacity(0.8) : MobileDesignSystem.Colors.errorRed
        }
    }

    private func foregroundColor(isPressed: Bool) -> Color {
        switch variant {
        case .primary, .destructive:
            return .white
        case .secondary:
            return MobileDesignSystem.Colors.textPrimary
        }
    }
}

extension View {
    public func mobileParakeetAction(_ variant: MobileParakeetButtonStyle.Variant = .primary) -> some View {
        self.buttonStyle(MobileParakeetButtonStyle(variant: variant))
    }

    @ViewBuilder
    public func mobileNavigationBarTitleDisplayModeInline() -> some View {
        #if os(iOS)
        self.navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }
}
