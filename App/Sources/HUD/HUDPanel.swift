import AppKit

/// The proactive HUD's floating panel — a compact companion at the top-left.
/// Unlike the pill, it's a SOLID panel with normal hit-testing (so its rows and
/// buttons are clickable and expose Accessibility ids for the probe). It never
/// activates Osmo or steals the caret: `canBecomeKey` stays false in phase 1
/// (no text field yet), so clicking a row's Draft button acts without pulling
/// focus from wherever the user is working.
final class HUDPanel: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 56),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false                 // drawn in SwiftUI on the glass shape
        hidesOnDeactivate = false
        isMovableByWindowBackground = true // drag it anywhere by its background
        becomesKeyOnlyIfNeeded = true
        appearance = NSAppearance(named: .aqua)
        // Expose as a real window so the AX probe (and VoiceOver) can find it.
        setAccessibilityRole(.window)
        setAccessibilityLabel("Osmo HUD")
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func present() { orderFrontRegardless() }
}
