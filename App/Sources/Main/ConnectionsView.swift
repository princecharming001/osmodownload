import SwiftUI
import OsmoCore

/// Connections: one row per platform with live status + Connect/Reconnect/Fix.
/// The target of every empty-state CTA.
struct ConnectionsView: View {
    @EnvironmentObject var model: AppModel
    /// Observed DIRECTLY: ConnectionsManager is a nested ObservableObject —
    /// SwiftUI does not observe through `model.connections.phases`, so without
    /// this the page only re-renders when something else publishes (the
    /// "Cancel/Connect click doesn't update the row" stale-state bug).
    @ObservedObject private var connections: ConnectionsManager

    init(connections: ConnectionsManager) {
        self.connections = connections
    }

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
                VStack(spacing: 0) {
                    ForEach(Platform.allCases, id: \.self) { platform in
                        ConnectionRow(platform: platform, connections: connections)
                    }
                }
            }
            .padding(DS.Space.xl)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        // Showing Connections is a good moment to verify liveness (last-sync
        // freshness per platform) — cheap and on-view only.
        .task { await model.connections.reconcile(verify: true) }
    }
}

struct ConnectionRow: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var connections: ConnectionsManager
    let platform: Platform
    @State private var confirmDisconnect = false

    init(platform: Platform, connections: ConnectionsManager) {
        self.platform = platform
        self.connections = connections
    }

    var body: some View {
        // Transparent row (no card fill) so the brand logos read cleanly; a
        // hairline separates rows instead of a background tile.
        VStack(spacing: DS.Space.s) {
            HStack(spacing: DS.Space.m) {
                PlatformLogo(platform, size: 26)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(platform.displayName).font(DS.Typography.bodyEm).foregroundStyle(DS.Colors.ink)
                    HStack(spacing: DS.Space.xs) {
                        StatusDot(importFraction != nil ? .active : dotState)
                        Text(subtitle).font(DS.Typography.caption).foregroundStyle(DS.Colors.muted)
                            .accessibilityIdentifier("connections.status.\(platform.rawValue)")
                    }
                }
                Spacer()
                if importFraction == nil {
                    actions
                } else {
                    // Mid-import: let the user bail out of a long/stuck load.
                    Button("Stop") { model.stopImport(platform) }
                        .font(DS.Typography.captionEm).buttonStyle(.plain)
                        .foregroundStyle(DS.Colors.muted)
                }
            }
            if let fraction = importFraction {
                ProgressView(value: fraction)
                    .accessibilityHidden(true)
                    .tint(DS.Colors.accent)
                    .transition(.opacity)
            }
        }
        .padding(.vertical, DS.Space.m)
        .overlay(alignment: .bottom) {
            Rectangle().fill(DS.Colors.hairlineSoft).frame(height: 1)
        }
        .animation(DS.Motion.standard, value: importFraction)
    }

    /// Import fraction while a first-time backfill is running (nil = not importing).
    private var importFraction: Double? {
        guard let f = model.importProgress[platform], f < 1.0 else { return nil }
        return max(f, 0.02)   // always show a sliver so it reads as "started"
    }

    private var subtitle: String {
        if let f = importFraction {
            return "Importing your messages… \(Int(f * 100))%"
        }
        if case .live = phase, messageCount > 0 {
            var s = "Connected · \(messageCount.formatted()) messages"
            if let lastSync = connections.lastSyncByPlatform[platform] {
                let rel = Self.relativeFormatter.localizedString(for: lastSync, relativeTo: Date())
                s += " · synced \(rel)"
            }
            return s
        }
        return statusLabel
    }

    /// One shared formatter — allocating per row per render is measurable churn.
    private static let relativeFormatter = RelativeDateTimeFormatter()

    private var messageCount: Int {
        model.messageCountByPlatform[platform] ?? 0
    }

    private var phase: ConnectionPhase { connections.phases[platform] ?? .notConnected }

    @ViewBuilder private var actions: some View {
        if platform.comingSoon {
            Text("Coming soon").font(DS.Typography.captionEm).foregroundStyle(DS.Colors.muted)
        } else {
            connectActions
        }
    }

    @ViewBuilder private var connectActions: some View {
        switch phase {
        case .notConnected:
            if platform == .imessage && model.iMessageAwaitingRelaunch {
                // FDA was just granted but this process cached the old denial —
                // one click to relaunch and finish enabling iMessage.
                PillButton("Relaunch to finish", icon: "arrow.clockwise") { model.relaunchApp() }
            } else {
                PillButton(platform == .imessage ? "Enable" : "Connect") { model.connect(platform) }
                    .accessibilityIdentifier("connections.connect.\(platform.rawValue)")
            }
        case .linking:
            HStack(spacing: DS.Space.s) {
                // AX-hidden: an animating spinner in the accessibility tree
                // forces constant node re-materialization (starves the main
                // thread under AX walkers/VoiceOver); the status text already
                // says "Waiting for authorization…".
                ProgressView().controlSize(.small).accessibilityHidden(true)
                Button("Cancel") { Task { await model.connections.cancelConnect(platform) } }
                    .font(DS.Typography.captionEm).buttonStyle(.plain).foregroundStyle(DS.Colors.muted)
                    .accessibilityIdentifier("connections.cancel.\(platform.rawValue)")
                Button("Retry") {
                    Task { await model.connections.cancelConnect(platform); model.connect(platform) }
                }
                .font(DS.Typography.captionEm).buttonStyle(.plain).foregroundStyle(DS.Colors.accent)
            }
        case .backfilling(let progress):
            HStack(spacing: DS.Space.s) {
                ProgressView(value: progress).frame(width: 60).accessibilityHidden(true)
                Text("\(Int(progress * 100))%").font(DS.Typography.caption).foregroundStyle(DS.Colors.muted)
            }
        case .live:
            Menu {
                if platform != .imessage {
                    Button("Re-import full history") {
                        Task { await model.connections.reimportHistory(platform) }
                    }
                }
                Button("Pause") { Task { await model.connections.pause(platform, paused: true) } }
                Button("Disconnect", role: .destructive) { confirmDisconnect = true }
            } label: {
                // A chevron so this reads as a manageable control, not static status text.
                HStack(spacing: 3) {
                    Text("Connected").font(DS.Typography.captionEm)
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                }.foregroundStyle(DS.Colors.muted)
            }
                .menuStyle(.borderlessButton).fixedSize()
                .accessibilityLabel("Manage \(platform.displayName) connection")
                .accessibilityIdentifier("connections.manage.\(platform.rawValue)")
                .confirmationDialog("Disconnect \(platform.displayName)?",
                                    isPresented: $confirmDisconnect, titleVisibility: .visible) {
                    Button("Disconnect", role: .destructive) {
                        Task { await model.connections.disconnect(platform) }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("You'll stop syncing new messages. Already-imported messages stay, and you can reconnect anytime.")
                }
        case .degraded:
            // Reconnecting is recovery, not a destructive act — primary, matching
            // the strictly-worse .disconnected state (no red-alarm inversion).
            PillButton("Reconnect") { model.connect(platform) }
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
        if platform.comingSoon { return "Support in progress — not connectable yet" }
        switch phase {
        case .notConnected:
            if platform == .imessage && model.iMessageAwaitingRelaunch {
                return "Granted Full Disk Access? Relaunch Osmo to finish."
            }
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
                // Search-or-ask: the same query, answered instead of matched.
                askRow
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

    /// "Ask Osmo" card at the top of results: turns the query into a grounded
    /// question; the latest answer renders inline right below.
    @ViewBuilder private var askRow: some View {
        Button {
            model.askOsmo(model.searchText)
        } label: {
            HStack(spacing: DS.Space.s) {
                AskOrb(mode: model.askBusy ? .thinking : .idle, size: 20)
                Text("Ask Osmo: “\(model.searchText)”")
                    .font(DS.Typography.bodyEm).foregroundStyle(DS.Colors.ink).lineLimit(1)
                Spacer()
                if !model.askBusy {
                    Image(systemName: "return").font(.system(size: 10)).foregroundStyle(DS.Colors.muted)
                }
            }
            .padding(DS.Space.m)
            .background(DS.Colors.accent.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: DS.Radius.l, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.l, style: .continuous)
                .stroke(DS.Colors.accent.opacity(0.25), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(model.askBusy)
        if let last = model.askExchanges.last, last.q == model.searchText.trimmingCharacters(in: .whitespacesAndNewlines) {
            Card {
                HStack(alignment: .top, spacing: DS.Space.s) {
                    AskOrb(mode: .idle, size: 18)
                    Text(last.a).font(DS.Typography.body).foregroundStyle(DS.Colors.ink)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func open(_ message: OsmoMessage) {
        model.selectedThreadID = message.threadID
        model.searchText = ""
        model.section = .inbox
    }
}
