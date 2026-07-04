import AppKit
import ApplicationServices

/// Best-effort AX reads of the current moment — the retained "screen reading"
/// fallback path. Reads the existing draft out of a focused field, and inserts
/// text back into it (AX first, ⌘V paste as fallback).
enum ScreenContextReader {

    /// Existing text in the focused compose field (so the pill can continue a draft).
    static func draftText(from element: AXUIElement) -> String? {
        var value: AnyObject?
        AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value)
        let text = value as? String
        return (text?.isEmpty ?? true) ? nil : text
    }

    /// Insert text into a focused field: try AX setValue on the app's focused
    /// element; if that fails, fall back to a synthesized ⌘V paste with the prior
    /// pasteboard restored.
    @MainActor
    static func insert(_ text: String, into element: AXUIElement?) {
        if let element {
            let existing = draftText(from: element) ?? ""
            let combined = existing.isEmpty ? text : existing + text
            let result = AXUIElementSetAttributeValue(
                element, kAXValueAttribute as CFString, combined as CFString)
            if result == .success { return }
        }
        pasteFallback(text)
    }

    @MainActor
    private static func pasteFallback(_ text: String) {
        let pasteboard = NSPasteboard.general
        let prior = pasteboard.string(forType: .string)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        let source = CGEventSource(stateID: .combinedSessionState)
        let vKey: CGKeyCode = 9   // 'v'
        let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true)
        down?.flags = .maskCommand
        let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)

        // Restore the user's clipboard shortly after.
        if let prior {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                pasteboard.clearContents()
                pasteboard.setString(prior, forType: .string)
            }
        }
    }
}
