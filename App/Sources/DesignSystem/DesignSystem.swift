import SwiftUI

/// Osmo's visual language — orchid.ai light-luxury minimalism. Paper grounds,
/// deep navy ink, ALL hairlines/shadows are ink-alpha (never gray), iOS-native
/// blue accent, in-between SF weights, one serif moment, real glass.
public enum DS {

    public enum Colors {
        public static let paper  = Color(hex: 0xFCFCFD)   // page ground
        public static let ink    = Color(hex: 0x08152E)   // brand neutral
        public static let card   = Color(hex: 0xF5F6F8)
        public static let chip   = Color(hex: 0xEBEEF2)
        public static let muted  = Color(hex: 0x95A0AA)
        public static let cream  = Color(hex: 0xF5F3EC)   // onboarding warm ground
        public static let accent = Color(hex: 0x0A84FF)   // iOS systemBlue
        public static let red    = Color(hex: 0xFF383C)   // iOS systemRed
        public static let green  = Color(hex: 0x30D158)   // connected dot (used sparingly)

        // Ink-alpha hairlines + shadows (the orchid tell — never gray).
        public static let hairline     = ink.opacity(0.10)
        public static let hairlineSoft = ink.opacity(0.06)
        public static let inkStrong    = ink.opacity(0.40)
        public static let shadow       = ink.opacity(0.28)

        // Glass tokens.
        public static let glassFill   = Color.white.opacity(0.25)
        public static let glassTint   = Color.white.opacity(0.55)
        public static let glassBorder = ink.opacity(0.10)
        public static let glassTopEdge = Color.white.opacity(0.18)
    }

    /// SF Pro, in-between weights (regular↔medium, never heavy). One serif for
    /// hero moments only.
    public enum Typography {
        public static let display = Font.system(size: 28, weight: .semibold, design: .serif)
        public static let displaySmall = Font.system(size: 22, weight: .semibold, design: .serif)
        public static let title   = Font.system(size: 18, weight: .medium)
        public static let heading = Font.system(size: 16, weight: .medium)
        public static let body    = Font.system(size: 14, weight: .regular)
        public static let bodyEm  = Font.system(size: 14, weight: .medium)
        public static let caption = Font.system(size: 12, weight: .regular)
        public static let captionEm = Font.system(size: 12, weight: .medium)
        public static let eyebrow = Font.system(size: 11, weight: .medium)
    }

    public enum Space {
        public static let xs: CGFloat = 4
        public static let s: CGFloat = 8
        public static let m: CGFloat = 12
        public static let l: CGFloat = 16
        public static let xl: CGFloat = 24
        public static let xxl: CGFloat = 32
    }

    public enum Radius {
        public static let s: CGFloat = 6
        public static let m: CGFloat = 8
        public static let l: CGFloat = 12
        public static let xl: CGFloat = 16
        public static let xxl: CGFloat = 24
        public static let pill: CGFloat = 999
    }

    public enum Motion {
        public static let standard = Animation.easeOut(duration: 0.15)
        public static let expoOut  = Animation.timingCurve(0.16, 1, 0.3, 1, duration: 0.3)
        public static let morph    = Animation.spring(response: 0.35, dampingFraction: 0.8)
        public static let pop      = Animation.spring(response: 0.3, dampingFraction: 0.6)
    }
}

public extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1)
    }
}

public extension Font {
    // Convenience aliases so views read cleanly.
    static let osmoDisplay = DS.Typography.display
    static let osmoTitle = DS.Typography.title
    static let osmoHeading = DS.Typography.heading
    static let osmoBody = DS.Typography.body
    static let osmoBodyEm = DS.Typography.bodyEm
    static let osmoCaption = DS.Typography.caption
    static let osmoEyebrow = DS.Typography.eyebrow
}
