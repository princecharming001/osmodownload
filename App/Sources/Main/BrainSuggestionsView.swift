import SwiftUI
import OsmoShell

/// The proactive brain's home in the main window (Today). Reach-out / gesture /
/// hold-back suggestions rendered as considered cards — so the "second brain"
/// isn't hidden behind the ⇧⌥Space HUD. Self-hides when the feed is empty (the
/// brain is off, or it has nothing worth saying), and mirrors the HUD feed's
/// actions so both surfaces agree on what acting/dismissing means.
struct BrainSuggestionsSection: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if !model.brainFeed.isEmpty {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                HStack(spacing: DS.Space.xs) {
                    Eyebrow("Osmo's read")
                    Spacer(minLength: 0)
                }
                VStack(spacing: DS.Space.s) {
                    ForEach(model.brainFeed) { item in
                        BrainCard(item: item)
                    }
                }
            }
            // Showing it on Today is a real impression — the same signal the HUD
            // records — so an unseen suggestion never counts as ignored.
            .onAppear { model.markFeedImpression(model.brainFeed.map(\.id)) }
        }
    }
}

private struct BrainCard: View {
    @EnvironmentObject var model: AppModel
    let item: BrainFeedItem
    @State private var hovering = false

    var body: some View {
        Card {
            HStack(alignment: .top, spacing: DS.Space.m) {
                avatar
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    // A gesture leads with its occasion — the "why now" is the point.
                    if item.kind == .gesture, let occasion = item.occasion, !occasion.isEmpty {
                        Text(occasion.uppercased())
                            .font(DS.Typography.eyebrow).tracking(0.6)
                            .foregroundStyle(item.isSensitive ? DS.Colors.amber : DS.Colors.accent)
                    }
                    Text(item.title)
                        .font(DS.Typography.bodyEm).foregroundStyle(DS.Colors.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    if let detail = item.detail, !detail.isEmpty {
                        Text(detail)
                            .font(DS.Typography.caption).foregroundStyle(DS.Colors.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    actions.padding(.top, DS.Space.xs)
                }
                Spacer(minLength: 0)
            }
        }
        .onHover { hovering = $0 }
    }

    /// Person avatar with a small kind-tinted badge — reads as "about this person,
    /// and here's the kind of move."
    private var avatar: some View {
        ZStack(alignment: .bottomTrailing) {
            AvatarView(name: item.displayName,
                       data: model.avatarData(forPerson: item.personID), size: 38)
            Image(systemName: badge)
                .font(.system(size: 8, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 16, height: 16)
                .background(badgeColor, in: Circle())
                .overlay(Circle().stroke(DS.Colors.card, lineWidth: 1.5))
        }
    }

    @ViewBuilder private var actions: some View {
        HStack(spacing: DS.Space.m) {
            switch item.kind {
            case .holdBack:
                // A hold-back is advice to WAIT — the only action is a neutral
                // acknowledge (recorded as neutral, never a rejection).
                PillButton("Got it", kind: .quiet) { dismiss() }
            case .reachOut, .gesture, .dateReminder:
                PillButton("Draft") { act() }
                Button("Not now") { dismiss() }
                    .font(DS.Typography.captionEm).buttonStyle(.plain)
                    .foregroundStyle(DS.Colors.muted)
            }
        }
    }

    private var badge: String {
        switch item.kind {
        case .reachOut:     return "arrow.up.forward"
        case .gesture:      return item.isSensitive ? "heart.fill" : "gift.fill"
        case .holdBack:     return "hourglass"
        case .dateReminder: return "calendar"
        }
    }

    private var badgeColor: Color {
        if item.isSensitive { return DS.Colors.amber }
        switch item.kind {
        case .holdBack: return DS.Colors.muted
        default:        return DS.Colors.accent
        }
    }

    private func act() {
        model.recordFeedAction(id: item.id, .acted)
        model.openThread(item.threadID)
    }
    private func dismiss() { model.recordFeedAction(id: item.id, .dismissed) }
}
