import SwiftUI
import AppKit

/// The Cluely-style overlay: a **non-activating** floating panel that appears
/// beside the messaging app you're in, shows three takes for the active
/// conversation, and never steals focus. This is the controller + panel scaffold;
/// the runtime wiring — global hotkey, `NSWorkspace` frontmost-app detection to
/// auto-summon, and AX/ScreenCaptureKit reading of the visible thread — lands with
/// the live bridges (needs a GUI session + permissions to verify). Compile-clean
/// so the surface exists and the panel behaves (non-activating, floats over
/// full-screen, joins all Spaces).
@MainActor
final class OverlayController {
    static let shared = OverlayController()
    private var panel: NSPanel?

    func toggle() {
        if let panel, panel.isVisible { panel.orderOut(nil) } else { show() }
    }

    private func show() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        // Position near the top-right of the main screen for now; real placement
        // follows the focused messaging window once AX reading is wired.
        if let screen = NSScreen.main {
            let size = NSSize(width: 380, height: 460)
            let origin = NSPoint(x: screen.visibleFrame.maxX - size.width - 24,
                                 y: screen.visibleFrame.maxY - size.height - 24)
            panel.setFrame(NSRect(origin: origin, size: size), display: true)
        }
        panel.orderFrontRegardless()
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 460),
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView, .closable],
            backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = NSColor(Theme.canvas)
        panel.contentView = NSHostingView(rootView: OverlayContent())
        return panel
    }
}

/// Placeholder overlay content until AX reading feeds it a live conversation. In
/// the running app this hosts a `SuggestionPanel` built from the focused thread.
struct OverlayContent: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Osmo").font(.osmoDisplay)
            Text("Open a conversation and Osmo will read it here, then draft three ways to reply in your voice.")
                .font(.osmoBody).foregroundStyle(Theme.muted)
            Spacer()
            Text("⌥Space to summon · reads the active thread locally")
                .font(.osmoCaption).foregroundStyle(Theme.muted)
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.canvas)
    }
}
