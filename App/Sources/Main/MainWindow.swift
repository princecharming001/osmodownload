import SwiftUI
import OsmoCore

/// The main window: orchid sidebar (Today / Inbox / People / Projects /
/// Connections) + a detail pane. Global search replaces the detail while active.
struct MainWindow: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(220)
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(DS.Colors.paper)
        }
        .background(DS.Colors.paper)
        .toast(model.toast) { model.toast = nil }
        .onAppear { model.reload() }
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
                        }
                    } icon: {
                        Image(systemName: section.icon)
                    }
                    .tag(section)
                }
            }
            .listStyle(.sidebar)

            Divider()
            syncRow
        }
        .background(DS.Colors.card)
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
            case .projects: ProjectsView()
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
            TextField("Search everyone, everything…", text: $text)
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
