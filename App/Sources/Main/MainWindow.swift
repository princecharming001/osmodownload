import SwiftUI
import OsmoCore

/// The main window: orchid sidebar (Today / Inbox / People / Projects /
/// Connections) + a detail pane. Global search replaces the detail while active.
struct MainWindow: View {
    @EnvironmentObject var model: AppModel

    @AppStorage("acceptedLegalV1") private var acceptedLegal = false

    var body: some View {
        VStack(spacing: 0) {
            incidentBanner
            NavigationSplitView {
                sidebar
                    .navigationSplitViewColumnWidth(220)
            } detail: {
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(DS.Colors.paper)
            }
        }
        .background(DS.Colors.paper)
        .background(sectionShortcuts)
        .toast(model.toast) { model.toast = nil }
        .sheet(item: $model.activeSheet) { sheet in sheetContent(sheet) }
        .onAppear {
            model.reload()
            if !acceptedLegal { model.activeSheet = .consent }
        }
    }

    /// Keyboard navigation: ⌘1–⌘5 jump between sections, ⌘R syncs. Zero-size and
    /// AX-hidden, they add fast switching for power users (and give UI tests a
    /// stable way in — a NavigationSplitView's List rows don't expose their own
    /// identifiers reliably).
    private var sectionShortcuts: some View {
        Group {
            Button("") { model.section = .today }.keyboardShortcut("1", modifiers: .command)
            Button("") { model.section = .inbox }.keyboardShortcut("2", modifiers: .command)
            Button("") { model.section = .people }.keyboardShortcut("3", modifiers: .command)
            Button("") { model.section = .you }.keyboardShortcut("4", modifiers: .command)
            Button("") { model.section = .connections }.keyboardShortcut("5", modifiers: .command)
            Button("") { Task { await model.sync() } }.keyboardShortcut("r", modifiers: .command)
        }
        .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
    }

    @ViewBuilder private func sheetContent(_ sheet: AppModel.AppSheet) -> some View {
        switch sheet {
        case .consent:
            LegalConsentView { acceptedLegal = true; model.activeSheet = nil }
                .interactiveDismissDisabled(true)
        case .whatsNew: WhatsNewView().environmentObject(model)
        case .paywall: PaywallView().environmentObject(model)
        case .feedback: FeedbackView().environmentObject(model)
        case .help: HelpView()
        case .account: ProfileView().environmentObject(model)
        }
    }

    /// The incident-banner message: a backend-reported status wins; otherwise a
    /// repeated realtime-pull failure (sync service unreachable) surfaces here.
    private var bannerMessage: String? {
        if let message = model.serviceStatusMessage { return message }
        if model.backendUnreachable { return "Can't reach Osmo's sync service — messages may be delayed." }
        return nil
    }

    /// App-wide incident banner — only when the backend reports trouble.
    @ViewBuilder private var incidentBanner: some View {
        if let message = bannerMessage {
            HStack(spacing: DS.Space.s) {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 11))
                    .accessibilityHidden(true)
                Text(message).font(DS.Typography.captionEm)
                Spacer()
            }
            .foregroundStyle(.white)
            .padding(.horizontal, DS.Space.l).padding(.vertical, 6)
            .background(DS.Colors.amber)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Service notice: \(message)")
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Osmo")
                .font(DS.Typography.displaySmall).foregroundStyle(DS.Colors.ink)
                .padding(.horizontal, DS.Space.l).padding(.top, DS.Space.l).padding(.bottom, DS.Space.m)

            SearchField(text: $model.searchText, onChange: { model.runSearch() })
                .padding(.horizontal, DS.Space.m)
                .padding(.bottom, DS.Space.s)

            List(selection: Binding(
                get: { model.section },
                set: { if let s = $0 { model.section = s } })) {
                ForEach(AppModel.Section.allCases) { section in
                    Label {
                        HStack {
                            Text(section.rawValue).font(DS.Typography.body)
                            Spacer()
                            if section == .today, owedCount > 0 {
                                Text("\(owedCount)").font(DS.Typography.eyebrow)
                                    .padding(.horizontal, 6).padding(.vertical, 1)
                                    .background(DS.Colors.accent, in: Capsule())
                                    .foregroundStyle(.white)
                            }
                            if section == .people, !model.mergeSuggestions.isEmpty {
                                StatusDot(.attention)
                            }
                            if section == .connections, model.degradedCount > 0 {
                                Text("\(model.degradedCount)").font(DS.Typography.eyebrow)
                                    .padding(.horizontal, 6).padding(.vertical, 1)
                                    .background(DS.Colors.red, in: Capsule())
                                    .foregroundStyle(.white)
                            }
                        }
                    } icon: {
                        Image(systemName: section.icon)
                    }
                    .tag(section)
                    .accessibilityIdentifier("sidebar.\(section.rawValue.lowercased())")
                }
            }
            .listStyle(.sidebar)

            Divider()
            accountRow
            Divider()
            syncRow
        }
        .background(DS.Colors.card)
    }

    /// The account footer — avatar + name + plan chip, opens the profile sheet.
    private var accountRow: some View {
        Button { model.activeSheet = .account } label: {
            HStack(spacing: DS.Space.s) {
                AvatarView(name: model.account.displayName.isEmpty ? "You" : model.account.displayName,
                           data: model.account.avatarData, size: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.account.displayName.isEmpty ? "Your account" : model.account.displayName)
                        .font(DS.Typography.captionEm).foregroundStyle(DS.Colors.ink).lineLimit(1)
                    Text(model.planName).font(DS.Typography.eyebrow).foregroundStyle(DS.Colors.muted)
                }
                Spacer()
                if !model.isPro {
                    Text("Upgrade").font(DS.Typography.eyebrow)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .foregroundStyle(.white).background(DS.Colors.accent, in: Capsule())
                }
            }
            .padding(.horizontal, DS.Space.m).padding(.vertical, DS.Space.s)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Account, plan & billing")
        .accessibilityIdentifier("sidebar.account")
    }

    private var syncRow: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            Button { Task { await model.sync() } } label: {
                Label(model.syncing ? "Syncing…" : "Sync now",
                      systemImage: "arrow.triangle.2.circlepath")
                    .font(DS.Typography.caption)
            }
            .buttonStyle(.plain).foregroundStyle(DS.Colors.muted)
            .disabled(model.syncing)
            .accessibilityIdentifier("sidebar.sync")
            if model.isMockMode {
                Text("Demo mode — connect a platform to sync real messages.")
                    .font(DS.Typography.eyebrow).foregroundStyle(DS.Colors.muted).lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DS.Space.m)
    }

    @ViewBuilder private var detail: some View {
        if !model.searchText.isEmpty {
            SearchResultsView()
        } else {
            switch model.section {
            case .today: TodayView()
            case .inbox: InboxView()
            case .people: PeopleView()
            case .you: YouView()
            case .connections: ConnectionsView()
            }
        }
    }

    private var owedCount: Int { model.queue.filter { $0.kind == .reply }.count }
}

/// An orchid search field.
struct SearchField: View {
    @Binding var text: String
    var onChange: () -> Void
    var body: some View {
        HStack(spacing: DS.Space.s) {
            Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(DS.Colors.muted)
            TextField("Search or ask anything…", text: $text)
                .textFieldStyle(.plain).font(DS.Typography.body)
                .onChange(of: text) { _, _ in onChange() }
            if !text.isEmpty {
                Button { text = ""; onChange() } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 12))
                }.buttonStyle(.plain).foregroundStyle(DS.Colors.muted)
            }
        }
        .padding(.horizontal, DS.Space.m).padding(.vertical, DS.Space.s)
        .background(DS.Colors.paper, in: Capsule())
        .overlay(Capsule().stroke(DS.Colors.hairline, lineWidth: 1))
    }
}

/// A lightweight toast overlay.
extension View {
    func toast(_ message: String?, dismiss: @escaping () -> Void) -> some View {
        overlay(alignment: .bottom) {
            if let message {
                Text(message)
                    .font(DS.Typography.captionEm).foregroundStyle(.white)
                    .padding(.horizontal, DS.Space.l).padding(.vertical, DS.Space.m)
                    .background(DS.Colors.ink, in: Capsule())
                    .shadow(color: DS.Colors.shadow, radius: 12, y: 4)
                    .padding(.bottom, DS.Space.xl)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { dismiss() }
                    }
            }
        }
        .animation(DS.Motion.expoOut, value: message)
    }
}
