import SwiftUI
import AppKit
import OsmoShell

/// Osmo — the consumer Mac app. A main window (Today / Inbox / People / Projects
/// / Connections), a menu-bar presence, the liquid-glass pill, and a full
/// onboarding takeover on first launch. Runs keyless; real connections inject
/// via the hosted-auth wizard.
@main
struct OsmoApp: App {
    @StateObject private var model = AppModel()
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
                Button("Replay Welcome…") { hasOnboarded = false }
            }
            CommandGroup(replacing: .newItem) {
                Button("New Project") { model.section = .projects }
                    .keyboardShortcut("n", modifiers: .command)
            }
            CommandGroup(after: .toolbar) {
                Button("Search") { model.section = .today }
                    .keyboardShortcut("k", modifiers: .command)
                Button("Summon Osmo") { PillController.shared.handleHotkey() }
                    .keyboardShortcut(.space, modifiers: .option)
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        HotkeyCenter.install { PillController.shared.handleHotkey() }
        NotificationCenter.default.addObserver(
            self, selector: #selector(didBecomeActive),
            name: NSApplication.didBecomeActiveNotification, object: nil)
    }

    @MainActor func activatePill() {
        guard !activated, let model else { return }
        activated = true
        PillController.shared.attach(model: model)
        startDetector()
    }

    @MainActor private func startDetector() {
        guard AXPermission.isTrusted, detector == nil else { return }
        let detector = TypingDetector()
        detector.onContext = { context in
            let pill = context.map {
                PillContext(bundleID: $0.bundleID, platform: $0.platform,
                            partnerName: $0.partnerName, draftText: $0.draftText, sourceURL: $0.url)
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
