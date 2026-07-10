import SwiftUI
import ServiceManagement
import KeyboardShortcuts
import OsmoCore
import OsmoBrain

/// Tabbed settings — General / Connections / Pill & Hotkey / AI / Notifications
/// / Privacy.
struct SettingsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gear") }
            PlanSettings().environmentObject(model)
                .tabItem { Label("Plan", systemImage: "creditcard") }
            ConnectionsView(connections: model.connections).environmentObject(model)
                .tabItem { Label("Connections", systemImage: "link") }
            PillSettings().tabItem { Label("Pill & Hotkey", systemImage: "capsule") }
            AISettings().tabItem { Label("AI", systemImage: "brain") }
            NotificationSettings().tabItem { Label("Notifications", systemImage: "bell") }
            PrivacySettings().tabItem { Label("Privacy", systemImage: "lock") }
        }
        .frame(width: 540, height: 560)
        .background(DS.Colors.paper)
    }
}

/// Plan & billing as a settings tab (same surface as the account sheet).
struct PlanSettings: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        ScrollView {
            PlanBillingView().environmentObject(model).padding(DS.Space.l)
        }
        .background(DS.Colors.paper)
    }
}

struct GeneralSettings: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("hasOnboarded") private var hasOnboarded = true
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Toggle("Launch Osmo at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, on in
                    try? on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
                }
            Section {
                Toggle("Demo mode", isOn: $model.demoMode)
                Text("Shows only the 5 most recent conversations per platform from the last 15 days. A view filter — nothing is deleted, and turning it off restores everything.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Button("Replay welcome…") { hasOnboarded = false }
            }
        }
        .formStyle(.grouped)
    }
}

struct PillSettings: View {
    @AppStorage("pill.autoAppear") private var autoAppear = true
    var body: some View {
        Form {
            Section("Summon shortcut") {
                KeyboardShortcuts.Recorder("Toggle Osmo", name: .togglePill)
            }
            Section("Auto-appear") {
                Toggle("Show the pill when I'm typing a message", isOn: $autoAppear)
                Text("Osmo watches only the message field of apps you're actively typing in (iMessage, Slack, WhatsApp, and messaging sites).")
                    .font(DS.Typography.caption).foregroundStyle(DS.Colors.muted)
            }
            Section {
                Button("Reset pill position") { PillController.shared.resetPosition() }
            }
        }
        .formStyle(.grouped)
    }
}

struct AISettings: View {
    @EnvironmentObject var model: AppModel
    @State private var proxyURL = ""
    @State private var token = ""
    @State private var modelName = ""
    @State private var backendURL = ""
    @State private var testState: String?

    var body: some View {
        Form {
            Section {
                HStack {
                    Toggle("Autodraft on arrival", isOn: $model.autodraftEnabled)
                    ProTag()
                }
                Text("When a priority conversation needs a reply, Osmo drafts one before you open it — never overwrites a reply you've already started typing. Capped at 30 a day.")
                    .font(DS.Typography.caption).foregroundStyle(DS.Colors.muted)
            }
            Section("AI proxy") {
                TextField("Proxy URL", text: $proxyURL, prompt: Text("http://localhost:3000/api/suggest"))
                TextField("Session token", text: $token, prompt: Text("Automatic — uses your signed-in device"))
                Text("Leave the token blank to authenticate automatically with your signed-in device. Enter one only to override with a specific proxy session token.")
                    .font(DS.Typography.caption).foregroundStyle(DS.Colors.muted)
                TextField("Model", text: $modelName, prompt: Text("claude-sonnet-5"))
            }
            Section("Connections backend") {
                TextField("Backend URL", text: $backendURL, prompt: Text("http://localhost:3000"))
            }
            Section {
                HStack {
                    Button("Save") { save() }
                    Button("Test connection") { Task { await test() } }
                    if let testState { Text(testState).font(DS.Typography.caption).foregroundStyle(DS.Colors.muted) }
                }
            }
            Text("The proxy holds the Anthropic key; the app never sees it. Runs on a keyless mock until reachable.")
                .font(DS.Typography.caption).foregroundStyle(DS.Colors.muted)
        }
        .formStyle(.grouped)
        .onAppear {
            proxyURL = model.config.proxyURL; token = model.config.manualAuthToken ?? ""
            modelName = model.config.model; backendURL = model.config.backendURL ?? ""
        }
    }

    private func save() {
        model.updateConfig(RuntimeConfig(
            proxyURL: proxyURL.isEmpty ? RuntimeConfig().proxyURL : proxyURL,
            authToken: token.isEmpty ? "local-dev" : token,
            model: modelName.isEmpty ? "claude-sonnet-5" : modelName,
            backendURL: backendURL.isEmpty ? "http://localhost:3000" : backendURL))
        testState = "Saved"
    }

    private func test() async {
        save(); testState = "Testing…"
        do {
            let result = try await model.service.suggest(SuggestionContext(
                relationshipLabel: "friend", platform: .imessage,
                transcript: [ThreadTurn(fromMe: false, text: "hey are we still on for friday")]))
            let first = result.set.takes.first?.text ?? ""
            testState = first.contains("[mock]") ? "Connected (mock — proxy unset/unreachable)"
                                                 : "Live ✓ — \(String(first.prefix(36)))…"
        } catch { testState = "Error: \(error)" }
    }
}

struct NotificationSettings: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("notif.inbound") private var inbound = true
    @AppStorage("notif.digestHour") private var digestHour = 9
    var body: some View {
        Form {
            Section {
                if model.notifier.authorized {
                    Toggle("New-message nudges", isOn: $inbound)
                    Stepper("Morning digest at \(digestHour):00", value: $digestHour, in: 5...11)
                } else {
                    Button("Enable notifications") { Task { await model.notifier.requestAuthorization() } }
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct PrivacySettings: View {
    @EnvironmentObject var model: AppModel
    @State private var confirmErase = false
    @State private var eraseText = ""

    var body: some View {
        Form {
            Section("Permissions") {
                HStack {
                    Text("Accessibility (the pill)")
                    Spacer()
                    if AXPermission.isTrusted {
                        Label("Granted", systemImage: "checkmark.circle.fill").foregroundStyle(DS.Colors.green)
                    } else {
                        Button("Grant") { AXPermission.promptIfNeeded() }
                    }
                }
            }
            Section("Profile enrichment") {
                Toggle("Look up public profiles (LinkedIn + web)", isOn: $model.enrichmentEnabled)
                Text("When you open a person, Osmo asks its backend to fetch their public LinkedIn profile and public web mentions. Only their name and LinkedIn handle are sent — never your messages.")
                    .font(DS.Typography.caption).foregroundStyle(DS.Colors.muted)
                Button("Clear fetched profiles") {
                    try? model.store.deleteAllEnrichments()
                    model.reload()
                    model.toast = "Fetched profiles cleared."
                }
            }
            Section("Your data") {
                Button("Export all data (JSON)…") { exportData() }
                Button("Reveal database in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([AppModel.storeURL()])
                }
                Button("Erase all local data…", role: .destructive) { confirmErase = true }
                    .foregroundStyle(DS.Colors.red)
            }
            Text("Osmo stores your messages only on this Mac, encrypted. Nothing is uploaded.")
                .font(DS.Typography.caption).foregroundStyle(DS.Colors.muted)
        }
        .formStyle(.grouped)
        .alert("Erase everything?", isPresented: $confirmErase) {
            TextField("Type ERASE", text: $eraseText)
            Button("Cancel", role: .cancel) { eraseText = "" }
            Button("Erase", role: .destructive) {
                if eraseText == "ERASE" { model.deleteAllData() }
                eraseText = ""
            }
        } message: {
            Text("This permanently deletes every message, person, and project on this Mac and returns Osmo to a fresh install. This can't be undone.")
        }
    }

    private func exportData() {
        guard let data = model.exportData() else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "osmo-export.json"
        // `.begin` (non-blocking) — an app-modal `.runModal()` session here
        // freezes every Osmo window (including the main window) until the
        // panel closes, which reads exactly like the reported "freeze".
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? data.write(to: url)
        }
    }
}
