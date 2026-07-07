import XCTest
import CoreGraphics
@testable import OsmoShell

/// Regression tests for the pill "freeze" — the panel hosts its content
/// bottom-anchored, so AppKit's bottom-left click coords must be flipped to match
/// SwiftUI's top-left interactive rects. The OLD code compared them directly and
/// every click on the pill passed through (dead pill). These pin the fix.
final class PillHitTestTests: XCTestCase {
    let panelH: CGFloat = 620   // PillPanel is 460x620

    /// The collapsed pill sits at the panel BOTTOM. SwiftUI reports it near the
    /// bottom in top-left coords (large y ~584...612). A real click on the visible
    /// pill arrives in AppKit bottom-left coords with SMALL y (~22). Must route in.
    func testClickOnBottomAnchoredPillIsInteractive() {
        let pillRect = CGRect(x: 216, y: 584, width: 28, height: 28)   // top-left
        let click = CGPoint(x: 230, y: 22)                              // AppKit bottom-left
        XCTAssertTrue(
            PillHitTest.isInteractive(point: click, rects: [pillRect], panelHeight: panelH),
            "A click on the bottom-anchored pill must hit its interactive rect (the freeze bug)")
    }

    /// The empty slack ABOVE the pill (large AppKit y) must pass clicks through to
    /// the app behind, or the invisible panel would eat input across the screen.
    func testClickInEmptyTopSlackPassesThrough() {
        let pillRect = CGRect(x: 216, y: 584, width: 28, height: 28)
        let click = CGPoint(x: 230, y: 600)   // near panel top in AppKit coords
        XCTAssertFalse(
            PillHitTest.isInteractive(point: click, rects: [pillRect], panelHeight: panelH),
            "Empty slack above the pill must pass clicks through")
    }

    /// Expanded panel fills most of the height (bottom-anchored). A click in the
    /// middle of the visible card must route in.
    func testExpandedPanelBodyIsInteractive() {
        let panelRect = CGRect(x: 0, y: 40, width: 460, height: 572)   // top-left
        let click = CGPoint(x: 230, y: 300)                            // AppKit
        XCTAssertTrue(
            PillHitTest.isInteractive(point: click, rects: [panelRect], panelHeight: panelH))
    }

    /// No reported shape → everything passes through (never trap input with a
    /// stale/empty rect).
    func testEmptyRectsPassThrough() {
        XCTAssertFalse(
            PillHitTest.isInteractive(point: CGPoint(x: 10, y: 10), rects: [], panelHeight: panelH))
    }

    /// The old (buggy) direct comparison would have said the pill click is NOT on
    /// the rect — this documents exactly what regressed, so it can't silently return.
    func testUnflippedComparisonWouldMiss_documentsRegression() {
        let pillRect = CGRect(x: 216, y: 584, width: 28, height: 28)
        let click = CGPoint(x: 230, y: 22)
        XCTAssertFalse(pillRect.contains(click),
                       "Sanity: the raw (unflipped) point misses — which is why the pill was dead")
        XCTAssertTrue(PillHitTest.isInteractive(point: click, rects: [pillRect], panelHeight: panelH),
                      "…and the flip fixes it")
    }
}
