import SwiftUI
import OsmoCore

/// The daily digest — grouped queue cards (Owed / Follow-ups / Goal nudges /
/// Reconnect), each opening the thread with a pre-fired suggestion. Empty state
/// when clear; a lazy notification-opt-in nudge after the first real sync.
struct TodayView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.xl) {
                header
                if model.queue.isEmpty {
                    if model.isMockMode {
                        EmptyStateView(
                            icon: "sparkles",
                            title: "Try Osmo now",
                            message: "You're in demo mode. Open Connections to link a platform, or press ⌥Space anywhere to summon the pill.",
                            cta: ("Open Connections", { model.section = .connections }))
                    } else {
                        EmptyStateView(icon: "checkmark.circle",
                                       title: "You're clear",
                                       message: "No one's waiting on you right now.")
                    }
                } else {
                    notificationNudge
                    ForEach(groups, id: \.title) { group in
                        section(group.title, cards: group.cards)
                    }
                }
            }
            .padding(DS.Space.xl)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            Eyebrow(greeting)
            Text("Today").font(DS.Typography.display).foregroundStyle(DS.Colors.ink)
        }
    }

    @ViewBuilder private var notificationNudge: some View {
        if !model.notifier.authorized {
            Card {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Want a morning nudge?").font(DS.Typography.bodyEm)
                        Text("Osmo can remind you who's waiting.").font(DS.Typography.caption)
                            .foregroundStyle(DS.Colors.muted)
                    }
                    Spacer()
                    PillButton("Enable") { Task { await model.notifier.requestAuthorization() } }
                }
            }
        }
    }

    private func section(_ title: String, cards: [QueueCard]) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            Eyebrow(title)
            ForEach(cards) { card in QueueCardRow(card: card) }
        }
    }

    private var groups: [(title: String, cards: [QueueCard])] {
        let byKind = Dictionary(grouping: model.queue, by: \.kind)
        var out: [(String, [QueueCard])] = []
        if let r = byKind[.reply] { out.append(("Owed replies", r)) }
        if let r = byKind[.leftOnRead] { out.append(("Follow-ups", r)) }
        if let r = byKind[.goalNudge] { out.append(("Goal nudges", r)) }
        if let r = byKind[.reconnect] { out.append(("Reconnect", r)) }
        return out
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<12: return "Good morning"
        case 12..<17: return "Good afternoon"
        default: return "Good evening"
        }
    }
}

/// One queue card → opens the thread in the inbox with a pre-fired draft.
struct QueueCardRow: View {
    @EnvironmentObject var model: AppModel
    let card: QueueCard

    var body: some View {
        Card {
            HStack(spacing: DS.Space.m) {
                AvatarView(name: card.personName, size: 38)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: DS.Space.s) {
                        Text(card.personName).font(DS.Typography.bodyEm).foregroundStyle(DS.Colors.ink)
                        Chip(card.platform.displayName, systemImage: card.platform.symbolName)
                    }
                    Text(card.reason).font(DS.Typography.caption).foregroundStyle(DS.Colors.muted).lineLimit(1)
                }
                Spacer()
                PillButton("Draft") { openThread() }
            }
        }
    }

    private func openThread() {
        model.focusedThreadID = card.threadID
        model.section = .inbox
        model.selectedThreadID = card.threadID
    }
}
