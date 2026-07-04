import Foundation
import ApplicationServices

/// Accessibility permission helpers — the single grant that powers both typing
/// detection and text insertion.
enum AXPermission {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Prompt (shows the system dialog + deep-links to Settings on first ask).
    static func promptIfNeeded() {
        // The key constant ("AXTrustedCheckOptionPrompt") is a nonisolated global
        // that Swift 6 flags; the string value is stable and documented.
        let options = ["AXTrustedCheckOptionPrompt": true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    /// Poll until trusted (onboarding + Settings re-verify), then call back on the
    /// main actor. Returns a cancel handle.
    @discardableResult
    static func poll(interval: TimeInterval = 1.0, onTrusted: @escaping @MainActor () -> Void) -> Timer {
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { t in
            if AXIsProcessTrusted() {
                t.invalidate()
                Task { @MainActor in onTrusted() }
            }
        }
        return timer
    }
}
