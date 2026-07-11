import SwiftUI
import OsmoCore
import OsmoShell

/// The HUD's SwiftUI content: a slim BAR (orb + "N need you" + expand) that
/// morphs into an OPEN feed of the brain's suggestions and the replies you owe.
/// Glass chrome; top-left home. Rows deep-link into the inbox.
struct HUDRootView: View {
    @ObservedObject var controller: HUDController
    @EnvironmentObject var model: AppModel

    var body: some View {
        Group {
            if controller.state.mode == .bar {
                HUDBar(controller: controller)
            } else {
                HUDOpen(controller: controller, model: model)
            }
        }
        .background(GlassSurface(shape: RoundedRectangle(cornerRadius: 18)))
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .shadow(color: DS.Colors.inkStrong.opacity(0.25), radius: 18, y: 8)
        .padding(6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

private struct HUDBar: View {
    @ObservedObject var controller: HUDController

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(LinearGradient(colors: [DS.Colors.amber, DS.Colors.ink],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 26, height: 26)
                .overlay(Image(systemName: "sparkles").font(.system(size: 12, weight: .bold)).foregroundStyle(.white))
            Text(HUDStateMachine.summary(owedCount: controller.state.owedCount))
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(DS.Colors.ink)
            Spacer()
            Button { controller.expand() } label: {
                Image(systemName: "chevron.down").font(.system(size: 12, weight: .bold))
                    .foregroundStyle(DS.Colors.inkStrong)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("hud.expand")
        }
        .padding(.horizontal, 16)
        .frame(height: 56)
        .contentShape(Rectangle())
        .onTapGesture { controller.expand() }
        .accessibilityIdentifier("hud.bar")
    }
}

private struct HUDOpen: View {
    @ObservedObject var controller: HUDController
    @ObservedObject var model: AppModel

    private var replyCards: [QueueCard] { model.queue.filter { $0.kind == .reply } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Osmo").font(.system(size: 15, weight: .bold)).foregroundStyle(DS.Colors.ink)
                Spacer()
                Button { controller.collapse() } label: {
                    Image(systemName: "chevron.up").font(.system(size: 12, weight: .bold))
                        .foregroundStyle(DS.Colors.inkStrong)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("hud.collapse")
            }
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 8)

            if model.brainFeed.isEmpty && replyCards.isEmpty {
                Text("You're all caught up.")
                    .font(.system(size: 13)).foregroundStyle(DS.Colors.inkStrong)
                    .padding(.horizontal, 16).padding(.vertical, 20)
                    .accessibilityIdentifier("hud.empty")
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(model.brainFeed) { item in
                            HUDFeedRow(item: item, controller: controller)
                        }
                        ForEach(replyCards) { card in
                            HUDReplyRow(card: card, controller: controller)
                        }
                    }
                    .padding(.horizontal, 10).padding(.bottom, 12)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("hud.open")
    }
}

private struct HUDFeedRow: View {
    let item: BrainFeedItem
    @ObservedObject var controller: HUDController

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(item.isSensitive ? DS.Colors.amber : DS.Colors.inkStrong)
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(DS.Colors.ink)
                if let detail = item.detail {
                    Text(detail).font(.system(size: 12)).foregroundStyle(DS.Colors.inkStrong).lineLimit(2)
                }
            }
            Spacer(minLength: 4)
            if item.kind != .holdBack {
                Button("Draft") { controller.act(feedID: item.id, threadID: item.threadID) }
                    .buttonStyle(.plain).font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DS.Colors.ink)
                    .accessibilityIdentifier("hud.draft.\(item.threadID.uuidString)")
            }
            Button { controller.dismiss(feedID: item.id) } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(DS.Colors.inkStrong)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("hud.dismiss.\(item.threadID.uuidString)")
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12).fill(DS.Colors.cream.opacity(0.5)))
        .accessibilityIdentifier("hud.row")
    }

    private var icon: String {
        switch item.kind {
        case .reachOut: return "arrow.up.forward"
        case .gesture: return item.isSensitive ? "heart" : "gift"
        case .holdBack: return "hourglass"
        case .dateReminder: return "calendar"
        }
    }
}

private struct HUDReplyRow: View {
    let card: QueueCard
    @ObservedObject var controller: HUDController

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "bubble.left")
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(DS.Colors.inkStrong)
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(card.personName).font(.system(size: 13, weight: .semibold)).foregroundStyle(DS.Colors.ink)
                Text(card.reason).font(.system(size: 12)).foregroundStyle(DS.Colors.inkStrong).lineLimit(2)
            }
            Spacer(minLength: 4)
            Button("Open") { controller.openThread(card.threadID) }
                .buttonStyle(.plain).font(.system(size: 12, weight: .semibold)).foregroundStyle(DS.Colors.ink)
                .accessibilityIdentifier("hud.open.\(card.threadID.uuidString)")
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12).fill(DS.Colors.cream.opacity(0.5)))
        .accessibilityIdentifier("hud.reply")
    }
}
