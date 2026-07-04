import SwiftUI
import OsmoCore

struct MainWindow: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        NavigationSplitView {
            List(AppModel.Section.allCases, selection: Binding(
                get: { model.section },
                set: { if let s = $0 { model.section = s } })) { section in
                Label(section.rawValue, systemImage: section.icon)
                    .font(.osmoBody)
                    .tag(section)
            }
            .navigationSplitViewColumnWidth(190)
            .listStyle(.sidebar)
            .safeAreaInset(edge: .top) {
                Text("Osmo").font(.osmoDisplay).foregroundStyle(Theme.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.top, 12)
            }
        } detail: {
            Group {
                switch model.section {
                case .queue: MorningQueueView()
                case .people: PeopleView()
                case .projects: ProjectsView()
                case .inbox: InboxView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.canvas)
        }
        .onAppear { model.reload() }
    }
}

/// A small status pill matching the core texting status.
struct StatusPill: View {
    let status: TextingStatus
    var body: some View {
        Text(status.label)
            .font(.osmoCaption)
            .foregroundStyle(isHot ? Theme.onAccent : Theme.muted)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(isHot ? Theme.accent : Theme.surface, in: Capsule())
            .overlay(Capsule().stroke(Theme.hairline, lineWidth: isHot ? 0 : 1))
    }
    private var isHot: Bool { status == .needsReply || status == .leftOnRead }
}

/// A circular avatar (photo or monogram).
struct Avatar: View {
    let name: String
    let data: Data?
    var size: CGFloat = 40
    var body: some View {
        Group {
            if let data, let img = NSImage(data: data) {
                Image(nsImage: img).resizable().scaledToFill()
            } else {
                Text(name.prefix(1).uppercased())
                    .font(.system(size: size * 0.4, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.surface)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().stroke(Theme.hairline, lineWidth: 0.5))
    }
}
