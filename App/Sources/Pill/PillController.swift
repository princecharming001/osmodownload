import AppKit
import SwiftUI
import Combine
import ApplicationServices
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

    /// The live focused compose field in the frontmost app (set by the detector),
    /// so a chosen reply can be written straight back into it.
    var focusedElement: AXUIElement?

    private init() {}

    /// Insert a chosen reply into the real compose field the user was typing in
    /// (AX setValue, ⌘V paste fallback). Returns whether we had a field to target.
    @discardableResult
    func insertIntoFocusedField(_ text: String) -> Bool {
        ScreenContextReader.insert(text, into: focusedElement)
        return focusedElement != nil
    }

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
        withAnimation(DS.Motion.morphPill) { state = next }
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
            positionPanel()
            panel.present()
        case .expanded, .generating:
            panel.wantsKey = true
            positionPanel()
            panel.present()
            // The text field becomes key on click without activating Osmo.
        }
        #if DEBUG
        writeDebugState()
        #endif
    }

    #if DEBUG
    /// DEBUG-only: publish the pill's current state + on-screen click point so an
    /// automated smoke can verify a REAL mouse click lands (the pill panel is a
    /// borderless non-activating NSPanel and is NOT exposed via Accessibility, so
    /// AX-driven probes can't see it — that's what produced false "green" runs).
    private func writeDebugState() {
        guard let panel else { return }
        let name: String
        switch state {
        case .hidden: name = "hidden"; case .idle: name = "idle"; case .ready: name = "ready"
        case .expanded: name = "expanded"; case .generating: name = "generating"
        }
        let f = panel.frame  // AppKit screen coords (bottom-left origin)
        // The pill sits bottom-center of the panel (8pt inset, 28pt orb).
        let pillCenterAppKit = CGPoint(x: f.midX, y: f.minY + 8 + 14)
        let screenH = NSScreen.main?.frame.height ?? 0
        // CoreGraphics event coords are top-left origin.
        let clickCG = CGPoint(x: pillCenterAppKit.x, y: screenH - pillCenterAppKit.y)
        let dict: [String: Any] = ["state": name, "clickX": clickCG.x, "clickY": clickCG.y]
        let url = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/Osmo/.pillstate-debug.json")
        if let data = try? JSONSerialization.data(withJSONObject: dict) { try? data.write(to: url) }
    }
    #endif

    // MARK: - Position (field-anchored, else persisted, clamped)

    private func positionPanel() {
        guard let panel else { return }
        let size = panel.frame.size
        // Preferred: pop up right next to the compose field the user is typing in.
        if let frame = state.context?.fieldFrame, let origin = anchorOrigin(for: frame, size: size) {
            panel.setFrameOrigin(origin)
            return
        }
        // Fallback: the persisted (dragged) position, else bottom-center.
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let origin: NSPoint
        if let saved = loadPosition() {
            origin = NSPoint(
                x: min(max(saved.x, visible.minX), visible.maxX - size.width),
                y: min(max(saved.y, visible.minY), visible.maxY - size.height))
        } else {
            origin = NSPoint(x: visible.midX - size.width / 2, y: visible.minY + 24)
        }
        panel.setFrameOrigin(origin)
    }

    /// Place the (bottom-anchored) content just above the field, horizontally
    /// centered on it, clamped to the field's screen. The pill/panel content sits
    /// at the bottom of the oversized panel (8pt inset), so aligning the panel's
    /// bottom-center to the field's top edge lands it beside the message bar.
    private func anchorOrigin(for field: CGRect, size: NSSize) -> NSPoint? {
        let anchorScreen = NSScreen.screens.first {
            $0.frame.contains(CGPoint(x: field.midX, y: field.midY))
        } ?? NSScreen.main
        guard let visible = anchorScreen?.visibleFrame else { return nil }
        let gap: CGFloat = 12, contentInset: CGFloat = 8
        var origin = NSPoint(x: field.midX - size.width / 2,
                             y: field.maxY + gap - contentInset)   // field top edge + gap
        origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
        origin.y = min(max(origin.y, visible.minY), visible.maxY - size.height)
        return origin
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
