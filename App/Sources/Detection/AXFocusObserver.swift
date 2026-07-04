import AppKit
import ApplicationServices

/// One AXObserver on a single app's PID, watching for focus changes to a text
/// field. Sets `AXManualAccessibility` on Electron/browser apps (their AX tree
/// is lazy). Degrades to a 1.5s poll if notifications don't fire.
@MainActor
final class AXFocusObserver {
    private let pid: pid_t
    private let bundleID: String
    private let needsManualAX: Bool
    private let appElement: AXUIElement
    private var observer: AXObserver?
    private var pollTimer: Timer?

    var onFocusedTextField: ((AXUIElement?, String?) -> Void)?
    var onFocusLeft: (() -> Void)?

    init(pid: pid_t, bundleID: String, needsManualAX: Bool) {
        self.pid = pid
        self.bundleID = bundleID
        self.needsManualAX = needsManualAX
        self.appElement = AXUIElementCreateApplication(pid)
    }

    func start() {
        if needsManualAX {
            AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        }
        installObserver()
        // Evaluate the current focus immediately.
        evaluateFocus()
        // Fallback poll in case notifications are flaky for this app.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.evaluateFocus() }
        }
    }

    func stop() {
        pollTimer?.invalidate(); pollTimer = nil
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(),
                                  AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        observer = nil
    }

    private func installObserver() {
        var obs: AXObserver?
        let callback: AXObserverCallback = { _, _, _, refcon in
            guard let refcon else { return }
            let me = Unmanaged<AXFocusObserver>.fromOpaque(refcon).takeUnretainedValue()
            Task { @MainActor in me.evaluateFocus() }
        }
        guard AXObserverCreate(pid, callback, &obs) == .success, let observer = obs else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        AXObserverAddNotification(observer, appElement,
                                  kAXFocusedUIElementChangedNotification as CFString, refcon)
        CFRunLoopAddSource(CFRunLoopGetCurrent(),
                           AXObserverGetRunLoopSource(observer), .defaultMode)
        self.observer = observer
    }

    private func evaluateFocus() {
        var focused: AnyObject?
        let result = AXUIElementCopyAttributeValue(
            appElement, kAXFocusedUIElementAttribute as CFString, &focused)
        guard result == .success, let element = focused else { onFocusLeft?(); return }
        let axElement = element as! AXUIElement

        var roleValue: AnyObject?
        AXUIElementCopyAttributeValue(axElement, kAXRoleAttribute as CFString, &roleValue)
        let role = roleValue as? String

        if role == (kAXTextAreaRole as String) || role == (kAXTextFieldRole as String) {
            onFocusedTextField?(axElement, windowTitle())
        } else {
            onFocusLeft?()
        }
    }

    private func windowTitle() -> String? {
        var window: AnyObject?
        AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &window)
        guard let window else { return nil }
        var title: AnyObject?
        AXUIElementCopyAttributeValue(window as! AXUIElement, kAXTitleAttribute as CFString, &title)
        return title as? String
    }
}
