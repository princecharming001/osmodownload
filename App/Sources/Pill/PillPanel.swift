import AppKit
import SwiftUI

/// The non-activating floating panel that hosts the pill. A small visible pill
/// lives inside an oversized transparent window so expansion never reframes it.
/// Clicking the pill never steals focus from wherever the user is typing.
final class PillPanel: NSPanel {
    /// SwiftUI reports the interactive shape(s); clicks outside them pass through.
    var interactiveRects: [CGRect] = []
    /// The panel accepts key input only while the expanded panel needs a text field.
    var wantsKey = false

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 340),
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
        // point is in window coords already (this view fills the window).
        for rect in panel.interactiveRects where rect.contains(point) {
            return super.hitTest(point)
        }
        return nil   // pass the click through to whatever is behind
    }
}
