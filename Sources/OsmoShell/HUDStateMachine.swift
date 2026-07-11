import Foundation
import CoreGraphics

/// The pure state of the proactive HUD — the compact companion panel that lives
/// at the top-left corner. Two states: a slim BAR (orb + how many things need
/// you) and an OPEN feed. Deterministic and unit-tested; the AppKit panel is a
/// thin shell over this.
public struct HUDState: Equatable, Sendable {
    public enum Mode: String, Sendable { case bar, open }
    public var mode: Mode
    /// How many things are waiting on the user (brain feed + replies owed).
    public var owedCount: Int

    public init(mode: Mode = .bar, owedCount: Int = 0) {
        self.mode = mode
        self.owedCount = owedCount
    }
}

public enum HUDStateMachine {
    public static let width: CGFloat = 380
    /// Bar content is 56pt tall inside an 8pt glass inset on each side (see
    /// HUDRootView) — the panel must be 56 + 16 so the glass + shadow aren't clipped.
    public static let barHeight: CGFloat = 72
    public static let openMaxHeight: CGFloat = 620

    public static func toggled(_ mode: HUDState.Mode) -> HUDState.Mode {
        mode == .bar ? .open : .bar
    }

    /// Panel size for a state. The bar is fixed; the open panel grows with its
    /// content up to a cap, so a near-empty feed doesn't leave a tall void.
    // Measured against the real HUD content (header ~40pt + glass inset + scroll
    // padding ≈ 68; a row is ~52pt of content + 6pt spacing ≈ 58) so the open
    // panel hugs its feed instead of leaving a tall glass void beneath it.
    public static func size(for state: HUDState, rowCount: Int,
                            rowHeight: CGFloat = 58, headerHeight: CGFloat = 68) -> CGSize {
        switch state.mode {
        case .bar:
            return CGSize(width: width, height: barHeight)
        case .open:
            let content = headerHeight + CGFloat(max(rowCount, 1)) * rowHeight
            return CGSize(width: width, height: min(content, openMaxHeight))
        }
    }

    /// The bar summary line — "3 need you" / "you're clear".
    public static func summary(owedCount: Int) -> String {
        switch owedCount {
        case 0: return "You're clear"
        case 1: return "1 needs you"
        default: return "\(owedCount) need you"
        }
    }

    /// Keep the panel's TOP-LEFT corner pinned as it grows, so an expanding feed
    /// grows DOWNWARD (never up off the top of the screen). AppKit frames are
    /// bottom-left origin, so preserving the top edge means moving origin.y as
    /// height changes.
    public static func originPinningTopLeft(oldFrame: CGRect, newSize: CGSize) -> CGPoint {
        let topY = oldFrame.origin.y + oldFrame.height
        return CGPoint(x: oldFrame.origin.x, y: topY - newSize.height)
    }

    /// Clamp the top-left anchor so the panel stays fully on `screen` with a small
    /// inset — used on first placement and on screen-param changes.
    public static func clampTopLeft(_ topLeft: CGPoint, size: CGSize,
                                    screen: CGRect, inset: CGFloat = 16) -> CGPoint {
        let maxX = screen.maxX - size.width - inset
        let minX = screen.minX + inset
        let x = min(max(topLeft.x, minX), max(minX, maxX))
        let maxY = screen.maxY - inset
        let minY = screen.minY + size.height + inset
        let y = min(max(topLeft.y, minY), max(minY, maxY))
        return CGPoint(x: x, y: y)
    }

    /// Default anchor: the top-left of the screen's visible frame, inset.
    public static func defaultTopLeft(screen: CGRect, inset: CGFloat = 16) -> CGPoint {
        CGPoint(x: screen.minX + inset, y: screen.maxY - inset)
    }
}
