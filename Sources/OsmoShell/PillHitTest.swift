import CoreGraphics

/// Pure hit-test geometry for the floating pill panel, isolated here so it can be
/// unit-tested WITHOUT a running app. This matters: the pill's non-functional
/// "freeze" was a coordinate-space bug in `NSView.hitTest`, and the previous UI
/// probe drove buttons via Accessibility — which bypasses `hitTest` entirely and
/// therefore reported a false "green". A pure function with a regression test
/// pins the actual math.
///
/// The panel hosts its content BOTTOM-anchored inside an oversized transparent
/// window. AppKit delivers click points in window **base coordinates**
/// (bottom-left origin), but SwiftUI reports the interactive shape via `.global`
/// in **top-left** origin. Comparing them directly means a click on the pill
/// (which sits at the panel's bottom → small AppKit y) is tested against a
/// top-anchored rect (large SwiftUI y) and misses — so the click passes through
/// and the pill is dead to input. Flipping Y by the panel height reconciles the
/// two systems.
public enum PillHitTest {
    /// - Parameters:
    ///   - point: click location in AppKit window base coords (bottom-left origin).
    ///   - rects: interactive shape(s) as reported by SwiftUI `.global` (top-left).
    ///   - panelHeight: the hosting view / panel height used to flip Y.
    /// - Returns: true if the click lands on interactive content (route it in),
    ///   false if it should pass through to the app behind.
    public static func isInteractive(point: CGPoint, rects: [CGRect], panelHeight: CGFloat) -> Bool {
        guard !rects.isEmpty else { return false }
        let flipped = CGPoint(x: point.x, y: panelHeight - point.y)
        return rects.contains { $0.contains(flipped) }
    }
}
