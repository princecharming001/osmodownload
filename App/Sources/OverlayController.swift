import SwiftUI
import AppKit
import OsmoCore
import OsmoBrain

/// The Cluely-style overlay: a non-activating floating panel summoned with a
/// global hotkey (⌥Space) or the menu bar. When summoned it shows the most urgent
/// reply you owe — three takes, ready to send — without stealing focus from
/// wherever you're texting.
///
/// The global hotkey and (future) AX reading of the on-screen conversation need
/// the Accessibility permission; until it's granted, the menu-bar "Summon" still
/// works and the overlay shows your top queue item. Auto-reading the currently
/// visible thread on any app is the enhancement that lands with AX wiring.
@MainActor
final class OverlayController {
    static let shared = OverlayController()
    private var panel: NSPanel?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private weak var model: AppModel?

    /// Called once at launch to bind the data model + install the hotkey.
    func attach(model: AppModel) {
        self.model = model
        installHotkey()
    }

    func toggle() {
        if let panel, panel.isVisible { panel.orderOut(nil) } else { show() }
    }

    private func show() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        if let screen = NSScreen.main {
            let size = NSSize(width: 400, height: 520)
            let origin = NSPoint(x: screen.visibleFrame.maxX - size.width - 24,
                                 y: screen.visibleFrame.maxY - size.height - 24)
            panel.setFrame(NSRect(origin: origin, size: size), display: true)
        }
        panel.orderFrontRegardless()
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 520),
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
        if let model {
            panel.contentView = NSHostingView(rootView: OverlayRoot().environmentObject(model))
        }
        return panel
    }

    /// ⌥Space toggles the overlay. Global monitor fires when other apps are front
    /// (needs Accessibility); local handles the case where Osmo itself is front.
    private func installHotkey() {
        let handler: (NSEvent) -> Void = { [weak self] event in
            guard event.modifierFlags.contains(.option), event.keyCode == 49 else { return }
            self?.toggle()
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { handler($0) }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in handler(e); return e }
    }
}

/// The overlay's live content: your most urgent reply, or a clear state.
struct OverlayRoot: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if let card = model.queue.first {
            SuggestionPanel(
                context: overlayContext(card),
                personName: card.personName,
                platform: card.platform,
                sendTarget: model.threads.first { $0.id == card.threadID }?.platformThreadID ?? "")
                .environmentObject(model)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Text("Osmo").font(.osmoDisplay)
                Text("You're clear. Open a conversation and summon Osmo (⌥Space) to draft a reply in your voice.")
                    .font(.osmoBody).foregroundStyle(Theme.muted)
                Spacer()
            }
            .padding(18)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Theme.canvas)
        }
    }

    private func overlayContext(_ card: QueueCard) -> SuggestionContext {
        let project = card.projectID.flatMap { pid in model.projects.first { $0.id == pid } }
        let memory = card.personID.flatMap { try? model.store.memory(forPerson: $0) }
        let transcript = (try? model.store.messages(inThread: card.threadID))?.suffix(20).map {
            ThreadTurn(fromMe: $0.isFromMe, text: $0.text, sentAt: $0.sentAt)
        } ?? []
        return SuggestionContext(
            relationshipLabel: project?.title ?? card.personName, platform: card.platform,
            goalText: project?.goalText, toneHint: project?.toneHint,
            boundaries: project?.boundaries ?? [], selfContext: project?.selfContext,
            relationshipMemory: memory?.promptContext, transcript: transcript,
            userIntent: card.suggestedMove)
    }
}
