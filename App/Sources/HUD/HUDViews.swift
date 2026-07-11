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
                HUDBar(controller: controller).transition(.opacity)
            } else {
                HUDOpen(controller: controller, model: model).transition(.opacity)
            }
        }
        .animation(DS.Motion.morphPill, value: controller.state.mode)
        .background(GlassSurface(shape: RoundedRectangle(cornerRadius: DS.Radius.xl)))
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.xl))
        .shadow(color: DS.Colors.shadow, radius: 18, y: 8)
        .padding(DS.Space.s)   // glass inset; the panel height accounts for this
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
                .font(DS.Typography.bodyEm)
                .foregroundStyle(DS.Colors.ink)
            Spacer()
            Button { controller.expand() } label: {
                Image(systemName: "chevron.down").font(.system(size: 12, weight: .medium))
                    .foregroundStyle(DS.Colors.inkStrong)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Expand Osmo")
            .accessibilityIdentifier("hud.expand")
        }
        .padding(.horizontal, DS.Space.l)
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
                Text("Osmo").font(DS.Typography.heading).foregroundStyle(DS.Colors.ink)
                Spacer()
                Button { controller.collapse() } label: {
                    Image(systemName: "chevron.up").font(.system(size: 12, weight: .medium))
                        .foregroundStyle(DS.Colors.inkStrong)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Collapse Osmo")
                .accessibilityIdentifier("hud.collapse")
            }
            .padding(.horizontal, DS.Space.l).padding(.top, DS.Space.m).padding(.bottom, DS.Space.s)

            if model.brainFeed.isEmpty && replyCards.isEmpty {
                Text("You're all caught up.")
                    .font(DS.Typography.caption).foregroundStyle(DS.Colors.inkStrong)
                    .padding(.horizontal, DS.Space.l).padding(.vertical, DS.Space.xl)
                    .accessibilityIdentifier("hud.empty")
            } else {
                ScrollView {
                    VStack(spacing: DS.Space.xs) {
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
        HStack(alignment: .top, spacing: DS.Space.s) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(item.isSensitive ? DS.Colors.amber : DS.Colors.inkStrong)
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(DS.Typography.captionEm).foregroundStyle(DS.Colors.ink)
                if let detail = item.detail {
                    Text(detail).font(DS.Typography.caption).foregroundStyle(DS.Colors.inkStrong).lineLimit(2)
                }
            }
            Spacer(minLength: DS.Space.xs)
            if item.kind == .holdBack {
                // A hold-back says "wait" — its only action is a NEUTRAL
                // acknowledge, never a reject (which would punish good advice).
                Button("Got it") { controller.dismiss(feedID: item.id) }
                    .buttonStyle(.plain).font(DS.Typography.captionEm)
                    .foregroundStyle(DS.Colors.muted)
                    .accessibilityIdentifier("hud.ack.\(item.threadID.uuidString)")
            } else {
                Button("Draft") { controller.act(feedID: item.id, threadID: item.threadID) }
                    .buttonStyle(.plain).font(DS.Typography.captionEm)
                    .foregroundStyle(DS.Colors.ink)
                    .accessibilityIdentifier("hud.draft.\(item.threadID.uuidString)")
                Button { controller.dismiss(feedID: item.id) } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .medium)).foregroundStyle(DS.Colors.inkStrong)
                        .frame(width: 22, height: 22).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
                .accessibilityIdentifier("hud.dismiss.\(item.threadID.uuidString)")
            }
        }
        .padding(DS.Space.s)
        .background(RoundedRectangle(cornerRadius: DS.Radius.l).fill(DS.Colors.card))
        .accessibilityIdentifier("hud.row.\(item.threadID.uuidString)")
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
        HStack(alignment: .top, spacing: DS.Space.s) {
            Image(systemName: "bubble.left")
                .font(.system(size: 13, weight: .medium)).foregroundStyle(DS.Colors.inkStrong)
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(card.personName).font(DS.Typography.captionEm).foregroundStyle(DS.Colors.ink)
                Text(card.reason).font(DS.Typography.caption).foregroundStyle(DS.Colors.inkStrong).lineLimit(2)
            }
            Spacer(minLength: DS.Space.xs)
            Button("Open") { controller.openThread(card.threadID) }
                .buttonStyle(.plain).font(DS.Typography.captionEm).foregroundStyle(DS.Colors.ink)
                .accessibilityIdentifier("hud.open.\(card.threadID.uuidString)")
        }
        .padding(DS.Space.s)
        .background(RoundedRectangle(cornerRadius: DS.Radius.l).fill(DS.Colors.card))
        .accessibilityIdentifier("hud.reply.\(card.threadID.uuidString)")
    }
}
