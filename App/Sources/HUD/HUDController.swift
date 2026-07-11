import AppKit
import SwiftUI
import Combine
import OsmoShell

/// Owns the HUD panel and drives the pure `HUDStateMachine`. The app attaches it
/// once at launch; a hotkey / menu-bar item toggles it. It watches the model's
/// brain feed + reply queue to keep the "N need you" count and the panel size
/// live.
@MainActor
final class HUDController: NSObject, ObservableObject, NSWindowDelegate {
    static let shared = HUDController()

    @Published private(set) var state = HUDState()
    private var panel: HUDPanel?
    private weak var model: AppModel?
    private var cancellables = Set<AnyCancellable>()
    private let positionKey = "hud.position"
    private var attached = false

    private override init() { super.init() }

    func attach(model: AppModel) {
        guard !attached else { return }   // singleton — never double-subscribe
        attached = true
        self.model = model
        // Owed-count = brain feed items + replies you owe.
        model.$brainFeed.combineLatest(model.$queue)
            .receive(on: RunLoop.main)
            .sink { [weak self] feed, queue in
                guard let self else { return }
                let owed = feed.count + queue.filter { $0.kind == .reply }.count
                if self.state.owedCount != owed { self.state.owedCount = owed }
                if self.panel?.isVisible == true {
                    self.resize()
                    self.markImpressionIfVisible()
                }
            }
            .store(in: &cancellables)
    }

    /// Confirmed impression: only when the OPEN feed is actually on screen do its
    /// decisions become `.surfaced`. A decision the user never saw stays fresh and
    /// expires neutral — it never counts as an ignored/soft-negative.
    private func markImpressionIfVisible() {
        guard panel?.isVisible == true, state.mode == .open, let model else { return }
        model.markFeedImpression(model.brainFeed.map(\.id))
    }

    // MARK: NSWindowDelegate — persist a dragged position

    private var moveSaveWork: DispatchWorkItem?
    nonisolated func windowDidMove(_ notification: Notification) {
        Task { @MainActor in
            self.moveSaveWork?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.persistPosition() }
            self.moveSaveWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
        }
    }

    // MARK: Toggle / show / hide

    func toggle() {
        ensurePanel()
        if panel?.isVisible == true, state.mode == .open {
            hide()
        } else if panel?.isVisible == true {
            state.mode = .open
            resize()
        } else {
            state.mode = .bar
            show()
        }
    }

    /// The menu-bar entry point: always show, opened.
    func summon() {
        ensurePanel()
        state.mode = .open
        show()
    }

    func show() {
        ensurePanel()
        position(initial: true)
        panel?.present()
        markImpressionIfVisible()
    }

    func hide() { panel?.orderOut(nil) }

    func expand() { state.mode = .open; resize(); markImpressionIfVisible() }
    func collapse() { state.mode = .bar; resize() }

    // MARK: Panel plumbing

    private func ensurePanel() {
        guard panel == nil, let model else { return }
        let p = HUDPanel()
        let hosting = NSHostingView(rootView:
            HUDRootView(controller: self).environmentObject(model))
        hosting.autoresizingMask = [.width, .height]
        p.contentView = hosting
        p.delegate = self   // windowDidMove → persist the dragged position
        panel = p
    }

    private var rowCount: Int {
        guard let model else { return 0 }
        return model.brainFeed.count + model.queue.filter { $0.kind == .reply }.count
    }

    private func resize() {
        guard let panel, let screen = (panel.screen ?? NSScreen.main)?.visibleFrame else { return }
        let size = HUDStateMachine.size(for: state, rowCount: rowCount)
        // Keep the top-left corner pinned so growth is downward, then clamp.
        var origin = HUDStateMachine.originPinningTopLeft(oldFrame: panel.frame, newSize: size)
        let topLeft = CGPoint(x: origin.x, y: origin.y + size.height)
        let clampedTopLeft = HUDStateMachine.clampTopLeft(topLeft, size: size, screen: screen)
        origin = CGPoint(x: clampedTopLeft.x, y: clampedTopLeft.y - size.height)
        panel.setFrame(NSRect(origin: origin, size: size), display: true, animate: true)
    }

    private func position(initial: Bool) {
        guard let panel, let screen = (panel.screen ?? NSScreen.main)?.visibleFrame else { return }
        let size = HUDStateMachine.size(for: state, rowCount: rowCount)
        let saved = savedTopLeft()
        let topLeft = saved ?? HUDStateMachine.defaultTopLeft(screen: screen)
        let clamped = HUDStateMachine.clampTopLeft(topLeft, size: size, screen: screen)
        panel.setFrame(NSRect(x: clamped.x, y: clamped.y - size.height,
                              width: size.width, height: size.height), display: true)
    }

    private func savedTopLeft() -> CGPoint? {
        let d = UserDefaults.standard
        guard d.object(forKey: "\(positionKey).x") != nil else { return nil }
        return CGPoint(x: d.double(forKey: "\(positionKey).x"),
                       y: d.double(forKey: "\(positionKey).y"))
    }

    func persistPosition() {
        guard let panel else { return }
        let d = UserDefaults.standard
        d.set(panel.frame.origin.x, forKey: "\(positionKey).x")
        d.set(panel.frame.origin.y + panel.frame.height, forKey: "\(positionKey).y")   // store top-left
    }

    // MARK: Row actions (feed → thread + feedback)

    func openThread(_ threadID: UUID) { model?.openThread(threadID) }
    func dismiss(feedID: String) { model?.recordFeedAction(id: feedID, .dismissed) }
    func act(feedID: String, threadID: UUID) {
        model?.recordFeedAction(id: feedID, .acted)
        model?.openThread(threadID)
    }
}
