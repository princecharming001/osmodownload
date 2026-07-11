import SwiftUI
import AppKit
import OsmoShell

/// Osmo — the consumer Mac app. A main window (Today / Inbox / People / You /
/// Connections), a menu-bar presence, the liquid-glass pill, and a full
/// onboarding takeover on first launch. Runs keyless; real connections inject
/// via the hosted-auth wizard.
@main
struct OsmoApp: App {
    @StateObject private var model = AppModel()
    @StateObject private var updater = UpdaterController()
    @AppStorage("hasOnboarded") private var hasOnboarded = false
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            Group {
                if hasOnboarded {
                    MainWindow()
                        .environmentObject(model)
                        .frame(minWidth: 940, minHeight: 640)
                        .onAppear { appDelegate.model = model; appDelegate.activatePill() }
                } else {
                    OnboardingFlow()
                        .environmentObject(model)
                        .frame(minWidth: 640, minHeight: 560)
                        // Attach the pill during onboarding too so the practice
                        // step can summon the REAL pill (the aha moment).
                        .onAppear { appDelegate.model = model; appDelegate.activatePill() }
                }
            }
            .preferredColorScheme(.light)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
                Button("My Account…") { model.present(.account) }
                Button("Replay Welcome…") { hasOnboarded = false }
            }
            CommandGroup(replacing: .help) {
                Button("Osmo Help") { model.present(.help) }
                Button("Send Feedback…") { model.present(.feedback) }
                Divider()
                Button("Terms of Service") {
                    if let u = URL(string: "https://osmo.app/terms") { NSWorkspace.shared.open(u) }
                }
                Button("Privacy Policy") {
                    if let u = URL(string: "https://osmo.app/privacy") { NSWorkspace.shared.open(u) }
                }
            }
            CommandGroup(replacing: .newItem) {
                // Goals are added per-person, so "new goal" means "go pick the
                // person" — labelled honestly rather than implying a blank composer.
                Button("Go to People") { model.section = .people }
                    .keyboardShortcut("n", modifiers: .command)
            }
            CommandGroup(after: .toolbar) {
                Button("Search") { model.focusSearchRequested = true }
                    .keyboardShortcut("k", modifiers: .command)
                Button("Summon Osmo") { PillController.shared.handleHotkey() }
                    .keyboardShortcut(.space, modifiers: .option)
                Button("Toggle Relationship HUD") { HUDController.shared.toggle() }
                    .keyboardShortcut(.space, modifiers: [.shift, .option])
                Divider()
                // Kinso-parity fast filters, one keystroke each.
                Button(model.unansweredOnly ? "Show All Conversations" : "Unanswered Only") {
                    model.unansweredOnly.toggle()
                    model.section = .inbox
                }
                .keyboardShortcut("u", modifiers: [.command, .shift])
                Button(model.inboxSort == .priority ? "Sort by Recency" : "Sort by Priority") {
                    model.inboxSort = model.inboxSort == .priority ? .recent : .priority
                    model.section = .inbox
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])
            }
        }

        MenuBarExtra("Osmo", systemImage: "sparkles") {
            MenuBarView().environmentObject(model)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView().environmentObject(model)
                .preferredColorScheme(.light)
        }
    }
}

/// Bridges AppKit lifecycle: installs the hotkey + typing detector, attaches the
/// pill, and re-verifies permissions on foreground.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?
    private var detector: TypingDetector?
    private var activated = false

    /// The UI-probe harness launches with OSMO_PROBE=1. Under it we skip ONLY the
    /// global hotkey registration: the `KeyboardShortcuts` listener requests macOS
    /// Input Monitoring (kTCCServiceListenEvent) at launch, which pops a SECURE
    /// system prompt a headless AX probe physically cannot click — blocking every
    /// scenario behind it (and Input Monitoring is cdhash-pinned, so it re-prompts
    /// on every dev rebuild; trusting the signing cert doesn't help). The pill
    /// itself still attaches normally so the main window's key/AX-ready timing is
    /// unchanged (skipping the whole pill made the modals probe flaky — it drives
    /// the main window before it became key). Real launches (no env var) are
    /// unaffected; the probe never exercises the hotkey.
    static var isProbe: Bool { ProcessInfo.processInfo.environment["OSMO_PROBE"] == "1" }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if !Self.isProbe {
            HotkeyCenter.install { PillController.shared.handleHotkey() }
            HotkeyCenter.installHUD { HUDController.shared.toggle() }
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(didBecomeActive),
            name: NSApplication.didBecomeActiveNotification, object: nil)
    }

    @MainActor func activatePill() {
        guard !activated, let model else { return }
        activated = true
        PillController.shared.attach(model: model)
        HUDController.shared.attach(model: model)   // no Input Monitoring — safe under probe
        startDetector()
    }

    @MainActor private func startDetector() {
        guard AXPermission.isTrusted, detector == nil else { return }
        let detector = TypingDetector()
        detector.onContext = { [weak detector] context in
            // Hand the live focused element to the controller so a chosen reply
            // can be written straight back into the real compose box.
            PillController.shared.focusedElement = detector?.focusedElement
            let pill = context.map {
                PillContext(bundleID: $0.bundleID, platform: $0.platform,
                            partnerName: $0.partnerName, draftText: $0.draftText,
                            sourceURL: $0.url, fieldFrame: $0.fieldFrame)
            }
            PillController.shared.contextDetected(pill)
        }
        detector.start()
        self.detector = detector
    }

    @objc private func didBecomeActive() {
        model?.onForeground()
        startDetector()   // AX may have been granted since launch
    }
}
