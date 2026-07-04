import SwiftUI

/// Osmo's visual language — warm, editorial, calm. Minimal token set; the app is
/// local-first and quiet, so restraint is the point.
enum Theme {
    static let ink = Color(red: 0.11, green: 0.10, blue: 0.09)
    static let muted = Color(red: 0.42, green: 0.40, blue: 0.37)
    static let canvas = Color(red: 0.96, green: 0.955, blue: 0.94)
    static let surface = Color(red: 0.99, green: 0.985, blue: 0.975)
    static let accent = Color(red: 0.10, green: 0.09, blue: 0.08)   // ink pill
    static let onAccent = Color(red: 0.97, green: 0.96, blue: 0.94)
    static let hairline = Color.black.opacity(0.08)
    static let gold = Color(red: 0.83, green: 0.63, blue: 0.09)

    static func statusColor(_ status: TextingStatusUI) -> Color {
        switch status {
        case .needsReply, .leftOnRead: return ink
        default: return muted
        }
    }
}

/// UI mirror of the core `TextingStatus` label set (kept UI-side so views don't
/// need to import the enum's storage concerns).
enum TextingStatusUI { case needsReply, leftOnRead, waiting, ghosted, quiet, sayHi }

extension Font {
    static let osmoDisplay = Font.system(size: 26, weight: .semibold, design: .serif)
    static let osmoTitle = Font.system(size: 16, weight: .semibold)
    static let osmoBody = Font.system(size: 14)
    static let osmoCaption = Font.system(size: 12)
    static let osmoEyebrow = Font.system(size: 11, weight: .semibold)
}
