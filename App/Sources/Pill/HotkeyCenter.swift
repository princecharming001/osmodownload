import Foundation
import KeyboardShortcuts

/// The pill's global summon shortcut (default ⌥Space, rebindable). The Recorder
/// UI is reused verbatim in onboarding + Settings.
extension KeyboardShortcuts.Name {
    static let togglePill = Self("togglePill", default: .init(.space, modifiers: [.option]))
}

@MainActor
enum HotkeyCenter {
    /// Install once at launch.
    static func install(onToggle: @escaping () -> Void) {
        KeyboardShortcuts.onKeyUp(for: .togglePill) { onToggle() }
    }
}
