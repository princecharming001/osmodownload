import SwiftUI

/// The menu-bar dropdown — owed count, top-3, summon, permission warning.
struct MenuBarView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack {
                Text("Osmo").font(DS.Typography.title)
                Spacer()
                if model.isMockMode { Chip("Demo") }
            }

            let owed = model.queue.filter { $0.kind == .reply }
            Text(owed.isEmpty ? "You're clear" : "\(owed.count) waiting on you")
                .font(DS.Typography.body).foregroundStyle(DS.Colors.muted)

            if !owed.isEmpty {
                ForEach(owed.prefix(3)) { card in
                    Button {
                        model.selectedThreadID = card.threadID
                        model.section = .inbox
                        NSApp.activate(ignoringOtherApps: true)
                    } label: {
                        HStack {
                            Text(card.personName).font(DS.Typography.caption)
                            Spacer()
                            Image(systemName: card.platform.symbolName)
                                .font(.system(size: 9)).foregroundStyle(card.platform.tint)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }

            Divider()

            if !AXPermission.isTrusted {
                Button {
                    AXPermission.promptIfNeeded()
                } label: {
                    Label("Grant Accessibility for the pill", systemImage: "exclamationmark.triangle")
                        .font(DS.Typography.caption).foregroundStyle(DS.Colors.red)
                }
                .buttonStyle(.plain)
            }

            Button("Summon Osmo (⌥Space)") { PillController.shared.handleHotkey() }
            Button("Open Osmo") { NSApp.activate(ignoringOtherApps: true) }
            Divider()
            Button("Quit Osmo") { NSApp.terminate(nil) }
        }
        .padding(DS.Space.m)
        .frame(width: 260)
    }
}
