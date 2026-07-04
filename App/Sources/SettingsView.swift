import SwiftUI
import OsmoCore
import OsmoBrain

/// Settings — the AI proxy connection (URL + token + model) and a live test. This
/// is where the app becomes fully live: point it at your deployed Osmo proxy (or
/// the local `web/` dev server) and paste your session token.
struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var proxyURL: String = ""
    @State private var token: String = ""
    @State private var modelName: String = ""
    @State private var testState: String?

    var body: some View {
        Form {
            Section("AI proxy") {
                TextField("Proxy URL", text: $proxyURL, prompt: Text("http://localhost:3000/api/suggest"))
                TextField("Session token", text: $token)
                TextField("Model", text: $modelName, prompt: Text("claude-sonnet-5"))
                Text("The proxy holds the Anthropic key. The app never sees it. Runs on a keyless mock until this is set and reachable.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                HStack {
                    Button("Save") { save() }
                    Button("Test connection") { Task { await test() } }
                    if let testState { Text(testState).font(.caption).foregroundStyle(.secondary) }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 320)
        .onAppear {
            proxyURL = model.config.proxyURL
            token = model.config.authToken
            modelName = model.config.model
        }
    }

    private func save() {
        model.updateConfig(RuntimeConfig(
            proxyURL: proxyURL.isEmpty ? RuntimeConfig().proxyURL : proxyURL,
            authToken: token.isEmpty ? "local-dev" : token,
            model: modelName.isEmpty ? "claude-sonnet-5" : modelName))
        testState = "Saved"
    }

    private func test() async {
        save()
        testState = "Testing…"
        do {
            let result = try await model.service.suggest(SuggestionContext(
                relationshipLabel: "friend", platform: .imessage,
                transcript: [ThreadTurn(fromMe: false, text: "hey are we still on for friday")]))
            let first = result.set.takes.first?.text ?? ""
            testState = first.contains("[mock]") ? "Connected (mock — proxy unreachable/unset)"
                                                  : "Live ✓ — \(String(first.prefix(40)))…"
        } catch {
            testState = "Error: \(error)"
        }
    }
}
