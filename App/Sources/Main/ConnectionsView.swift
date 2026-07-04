import SwiftUI
import OsmoCore

/// Connections: one row per platform with live status + Connect/Reconnect/Fix.
/// The target of every empty-state CTA.
struct ConnectionsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.l) {
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    Eyebrow("Bring your conversations in")
                    Text("Connections").font(DS.Typography.display).foregroundStyle(DS.Colors.ink)
                }
                if model.isMockMode {
                    Card {
                        HStack(spacing: DS.Space.s) {
                            Image(systemName: "wand.and.stars").foregroundStyle(DS.Colors.accent)
                            Text("Demo mode — connecting loads sample conversations so you can try everything. No real account is touched.")
                                .font(DS.Typography.caption).foregroundStyle(DS.Colors.muted)
                        }
                    }
                }
                ForEach(Platform.allCases, id: \.self) { platform in
                    ConnectionRow(platform: platform)
                }
            }
            .padding(DS.Space.xl)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }
}

struct ConnectionRow: View {
    @EnvironmentObject var model: AppModel
    let platform: Platform

    var body: some View {
        Card {
            HStack(spacing: DS.Space.m) {
                Image(systemName: platform.symbolName)
                    .font(.system(size: 16)).foregroundStyle(platform.tint)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(platform.displayName).font(DS.Typography.bodyEm).foregroundStyle(DS.Colors.ink)
                    HStack(spacing: DS.Space.xs) {
                        StatusDot(dotState)
                        Text(statusLabel).font(DS.Typography.caption).foregroundStyle(DS.Colors.muted)
                    }
                }
                Spacer()
                actions
            }
        }
    }

    private var phase: ConnectionPhase { model.connections.phases[platform] ?? .notConnected }

    @ViewBuilder private var actions: some View {
        switch phase {
        case .notConnected:
            PillButton(platform == .imessage ? "Enable" : "Connect") { model.connect(platform) }
        case .linking:
            HStack(spacing: DS.Space.s) {
                ProgressView().controlSize(.small)
                Button("Cancel") { Task { await model.connections.cancelConnect(platform) } }
                    .font(DS.Typography.captionEm).buttonStyle(.plain).foregroundStyle(DS.Colors.muted)
                Button("Retry") {
                    Task { await model.connections.cancelConnect(platform); model.connect(platform) }
                }
                .font(DS.Typography.captionEm).buttonStyle(.plain).foregroundStyle(DS.Colors.accent)
            }
        case .backfilling(let progress):
            HStack(spacing: DS.Space.s) {
                ProgressView(value: progress).frame(width: 60)
                Text("\(Int(progress * 100))%").font(DS.Typography.caption).foregroundStyle(DS.Colors.muted)
            }
        case .live:
            Menu {
                Button("Pause") { Task { await model.connections.pause(platform, paused: true) } }
                Button("Disconnect", role: .destructive) { Task { await model.connections.disconnect(platform) } }
            } label: { Text("Connected").font(DS.Typography.captionEm).foregroundStyle(DS.Colors.muted) }
                .menuStyle(.borderlessButton).fixedSize()
        case .degraded:
            PillButton("Reconnect", kind: .destructive) { model.connect(platform) }
        case .paused:
            PillButton("Resume", kind: .quiet) { Task { await model.connections.pause(platform, paused: false) } }
        case .disconnected:
            PillButton("Reconnect") { model.connect(platform) }
        }
    }

    private var dotState: StatusDot.State {
        switch phase {
        case .live: return .connected
        case .backfilling, .linking: return .active
        case .degraded: return .attention
        default: return .idle
        }
    }

    private var statusLabel: String {
        switch phase {
        case .notConnected:
            return platform.access == .overlayOnly ? "Works through the pill — connect for full history" : "Not connected"
        case .linking: return "Waiting for authorization…"
        case .backfilling: return "Importing history…"
        case .live: return "Live"
        case .degraded(let reason): return reason
        case .paused: return "Paused"
        case .disconnected: return "Disconnected"
        }
    }
}

/// FTS search results, grouped by thread.
struct SearchResultsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                Eyebrow("\(model.searchResults.count) results")
                if model.searchResults.isEmpty {
                    Text("No matches for “\(model.searchText)”.")
                        .font(DS.Typography.body).foregroundStyle(DS.Colors.muted)
                        .padding(.top, DS.Space.xl)
                } else {
                    ForEach(model.searchResults) { message in
                        Button { open(message) } label: {
                            Card {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: DS.Space.xs) {
                                        Image(systemName: message.platform.symbolName)
                                            .font(.system(size: 9)).foregroundStyle(message.platform.tint)
                                        Text(message.isFromMe ? "You" : "Them")
                                            .font(DS.Typography.eyebrow).foregroundStyle(DS.Colors.muted)
                                    }
                                    Text(message.text).font(DS.Typography.body)
                                        .foregroundStyle(DS.Colors.ink).lineLimit(2)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(DS.Space.xl)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private func open(_ message: OsmoMessage) {
        model.selectedThreadID = message.threadID
        model.searchText = ""
        model.section = .inbox
    }
}
