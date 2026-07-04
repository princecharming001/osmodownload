import AppKit
import ApplicationServices
import OsmoCore
import OsmoShell

/// A detected messaging moment — feeds the pill's context.
struct DetectedContext: Equatable {
    var bundleID: String
    var platform: Platform
    var partnerName: String?
    var draftText: String?
    var url: String?
}

/// Watches the frontmost app; when the user focuses a text field in an
/// allow-listed messaging surface, emits a DetectedContext (debounced). Needs
/// the one Accessibility grant. The pure allow-list/title rules live in
/// OsmoShell.AppAllowlist so they're unit-tested; this is the AX plumbing.
@MainActor
final class TypingDetector {
    private let allowlist = AppAllowlist.standard
    private let sniffer = BrowserURLSniffer()
    private var observer: AXFocusObserver?
    private var debounceWork: DispatchWorkItem?
    private var workspaceToken: NSObjectProtocol?
    private var running = false

    /// nil = context left the field / non-messaging app.
    var onContext: ((DetectedContext?) -> Void)?

    func start() {
        guard !running, AXPermission.isTrusted else { return }
        running = true
        workspaceToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main) { [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                Task { @MainActor in self?.frontmostChanged(app) }
            }
        // Attach to whatever's already frontmost.
        if let app = NSWorkspace.shared.frontmostApplication { frontmostChanged(app) }
    }

    func stop() {
        running = false
        observer?.stop(); observer = nil
        if let token = workspaceToken {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
        onContext?(nil)
    }

    private func frontmostChanged(_ app: NSRunningApplication) {
        observer?.stop(); observer = nil
        debounceWork?.cancel()   // drop any pending emit from the previous app
        guard let bundleID = app.bundleIdentifier, allowlist.isObservable(bundleID: bundleID) else {
            onContext?(nil)
            return
        }
        let observer = AXFocusObserver(
            pid: app.processIdentifier, bundleID: bundleID,
            needsManualAX: allowlist.needsManualAX(bundleID: bundleID))
        observer.onFocusedTextField = { [weak self] element, windowTitle in
            Task { @MainActor in self?.focusedField(bundleID: bundleID, element: element, windowTitle: windowTitle) }
        }
        observer.onFocusLeft = { [weak self] in
            Task { @MainActor in self?.debounceEmit(nil) }
        }
        observer.start()
        self.observer = observer
    }

    private func focusedField(bundleID: String, element: AXUIElement?, windowTitle: String?) {
        let url = sniffer.activeTabURL(bundleID: bundleID)
        guard let platform = allowlist.platform(bundleID: bundleID, url: url) else {
            debounceEmit(nil); return
        }
        let partner = WindowTitleParser.partnerName(bundleID: bundleID, windowTitle: windowTitle)
        let draft = element.flatMap { ScreenContextReader.draftText(from: $0) }
        debounceEmit(DetectedContext(bundleID: bundleID, platform: platform,
                                     partnerName: partner, draftText: draft, url: url))
    }

    private func debounceEmit(_ context: DetectedContext?) {
        debounceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.onContext?(context) }
        debounceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }
}
