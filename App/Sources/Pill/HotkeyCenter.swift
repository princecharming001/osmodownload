import Foundation
import KeyboardShortcuts

/// The pill's global summon shortcut (default ⌥Space, rebindable). The Recorder
/// UI is reused verbatim in onboarding + Settings.
extension KeyboardShortcuts.Name {
    static let togglePill = Self("togglePill", default: .init(.space, modifiers: [.option]))
    static let toggleHUD = Self("toggleHUD", default: .init(.space, modifiers: [.shift, .option]))
}

@MainActor
enum HotkeyCenter {
    /// Install once at launch.
    static func install(onToggle: @escaping () -> Void) {
        KeyboardShortcuts.onKeyUp(for: .togglePill) { onToggle() }
    }

    /// The HUD's global summon (⇧⌥Space). Same Input-Monitoring caveat as the
    /// pill hotkey, so it's registered only outside the probe (see AppDelegate).
    static func installHUD(onToggle: @escaping () -> Void) {
        KeyboardShortcuts.onKeyUp(for: .toggleHUD) { onToggle() }
    }
}
