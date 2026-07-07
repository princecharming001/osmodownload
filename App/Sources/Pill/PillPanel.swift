import AppKit
import SwiftUI
import OsmoShell

/// The non-activating floating panel that hosts the pill. A small visible pill
/// lives inside an oversized transparent window so expansion never reframes it.
/// Clicking the pill never steals focus from wherever the user is typing.
final class PillPanel: NSPanel {
    /// SwiftUI reports the interactive shape(s); clicks outside them pass through.
    var interactiveRects: [CGRect] = []
    /// The panel accepts key input only while the expanded panel needs a text field.
    var wantsKey = false

    init() {
        // Oversized + transparent: the pill sits at the bottom and the expanded
        // panel (who-picker + three takes + draft box + intent field) grows UP
        // into the slack, so it never clips or reframes the window.
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 620),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false                    // shadow is drawn in SwiftUI on the shape
        hidesOnDeactivate = false
        isMovableByWindowBackground = false  // custom drag on the pill only
        becomesKeyOnlyIfNeeded = true
        appearance = NSAppearance(named: .aqua)   // light-mode lock
    }

    override var canBecomeKey: Bool { wantsKey }
    override var canBecomeMain: Bool { false }

    /// Show without activating Osmo or stealing the user's caret.
    func present() { orderFrontRegardless() }
}

/// The content view: hit-tests only the reported interactive rects so the empty
/// slack around the pill is click-through to the app behind.
final class PillHitTestView: NSView {
    weak var panel: PillPanel?

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let panel else { return super.hitTest(point) }
        // `point` arrives in window BASE coords (bottom-left origin); the pill
        // reports `interactiveRects` in SwiftUI `.global` (top-left origin). They
        // must be reconciled by flipping Y — otherwise a click on the pill (which
        // sits at the panel BOTTOM = small AppKit y) is tested against a
        // top-anchored rect and misses, so the click passes through and the pill
        // is completely non-interactive. This was THE freeze. See PillHitTestTests.
        if PillHitTest.isInteractive(point: point, rects: panel.interactiveRects, panelHeight: bounds.height) {
            return super.hitTest(point)
        }
        return nil   // pass the click through to whatever is behind
    }
}
