import SwiftUI

/// Osmo — the Mac app. A main window (inbox / people / projects / morning queue),
/// a menu-bar presence, and the Cluely-style overlay (scaffolded in
/// `OverlayController`). Runs keyless; credentials + live bridges inject later.
@main
struct OsmoApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            MainWindow()
                .environmentObject(model)
                .frame(minWidth: 900, minHeight: 600)
                .background(Theme.canvas)
        }
        .windowStyle(.hiddenTitleBar)

        MenuBarExtra("Osmo", systemImage: "bubble.left.and.text.bubble.right") {
            MenuBarView().environmentObject(model)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView().environmentObject(model)
        }
    }
}

/// The menu-bar dropdown: queue count + quick summon of the overlay.
struct MenuBarView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Osmo").font(.osmoTitle)
            let owed = model.queue.filter { $0.kind == .reply }.count
            Text(owed == 0 ? "You're clear" : "\(owed) waiting on you")
                .font(.osmoBody).foregroundStyle(Theme.muted)
            Divider()
            Button("Open Osmo") { NSApp.activate(ignoringOtherApps: true) }
            Button("Summon overlay (⌥Space)") { OverlayController.shared.toggle() }
            Divider()
            Button("Quit") { NSApp.terminate(nil) }
        }
        .padding(14)
        .frame(width: 240)
    }
}
