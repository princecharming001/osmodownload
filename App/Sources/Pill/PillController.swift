import AppKit
import SwiftUI
import Combine
import OsmoCore
import OsmoShell

/// Owns the pill panel + drives the pure `PillStateMachine`. The app attaches it
/// once at launch; the typing detector and the hotkey feed it events.
@MainActor
final class PillController: ObservableObject {
    static let shared = PillController()

    @Published private(set) var state: PillState = .hidden
    @Published var interactiveRects: [CGRect] = [] {
        didSet { panel?.interactiveRects = interactiveRects }
    }

    private var panel: PillPanel?
    private weak var model: AppModel?
    private var positionSaveWork: DispatchWorkItem?

    private init() {}

    func attach(model: AppModel) {
        self.model = model
        ensurePanel()
        // Start collapsed-but-present so the pill is always summonable.
        apply(.hotkey)   // hidden → idle
    }

    // MARK: - Event intake

    func handleHotkey() { apply(.hotkey) }
    func contextDetected(_ context: PillContext?) { apply(.detected(context)) }
    func tapPill() { apply(.tapPill) }
    func escape() { apply(.escape) }
    func hide() { apply(.hide) }

    /// Onboarding practice: inject a canned context + expand immediately.
    func showPractice(partnerName: String) {
        let ctx = PillContext(platform: .imessage, partnerName: partnerName, isPractice: true)
        apply(.detected(ctx))
    }

    func beginGenerating() { apply(.generationStarted) }
    func finishGenerating() { apply(.generationFinished) }

    private func apply(_ event: PillStateMachine.Event) {
        let next = PillStateMachine.reduce(state, event)
        guard next != state else { return }
        withAnimation(DS.Motion.morph) { state = next }
        syncPanel()
    }

    // MARK: - Panel lifecycle

    private func ensurePanel() {
        guard panel == nil, let model else { return }
        let panel = PillPanel()
        let host = PillHitTestView()
        host.panel = panel
        let hosting = NSHostingView(rootView:
            PillRootView(controller: self).environmentObject(model))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.topAnchor.constraint(equalTo: host.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            hosting.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: host.trailingAnchor),
        ])
        panel.contentView = host
        self.panel = panel
        positionPanel()
    }

    private func syncPanel() {
        guard let panel else { return }
        switch state {
        case .hidden:
            panel.orderOut(nil)
        case .idle, .ready:
            panel.wantsKey = false
            repositionIfOffscreen()
            panel.present()
        case .expanded, .generating:
            panel.wantsKey = true
            repositionIfOffscreen()
            panel.present()
            // The text field becomes key on click without activating Osmo.
        }
    }

    /// Re-run positioning if the panel isn't fully on the active screen (handles
    /// early-launch geometry, display changes, and a stale saved position).
    private func repositionIfOffscreen() {
        guard let panel, let screen = NSScreen.main else { return }
        if !screen.visibleFrame.contains(panel.frame) { positionPanel() }
    }

    // MARK: - Position (persisted, clamped)

    private func positionPanel() {
        guard let panel, let screen = NSScreen.main else { return }
        let saved = loadPosition()
        let size = panel.frame.size
        let visible = screen.visibleFrame
        let origin: NSPoint
        if let saved {
            origin = NSPoint(
                x: min(max(saved.x, visible.minX), visible.maxX - size.width),
                y: min(max(saved.y, visible.minY), visible.maxY - size.height))
        } else {
            // Default: bottom-center, 24pt up.
            origin = NSPoint(x: visible.midX - size.width / 2, y: visible.minY + 24)
        }
        panel.setFrameOrigin(origin)
    }

    /// Called by the drag gesture; moves the window and debounces a save.
    func dragBy(_ delta: CGSize) {
        guard let panel else { return }
        var origin = panel.frame.origin
        origin.x += delta.width
        origin.y -= delta.height   // SwiftUI y-down → AppKit y-up
        panel.setFrameOrigin(origin)
        debounceSavePosition(origin)
    }

    private func debounceSavePosition(_ origin: NSPoint) {
        positionSaveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.savePosition(origin) }
        positionSaveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func savePosition(_ origin: NSPoint) {
        UserDefaults.standard.set(["x": origin.x, "y": origin.y], forKey: "pill.position")
    }
    private func loadPosition() -> NSPoint? {
        guard let dict = UserDefaults.standard.dictionary(forKey: "pill.position"),
              let x = dict["x"] as? CGFloat, let y = dict["y"] as? CGFloat else { return nil }
        return NSPoint(x: x, y: y)
    }

    func resetPosition() {
        UserDefaults.standard.removeObject(forKey: "pill.position")
        positionPanel()
    }
}
