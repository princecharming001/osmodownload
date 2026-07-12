import SwiftUI
import OsmoCore
import OsmoBrain

/// The daily digest — grouped queue cards (Owed / Follow-ups / Goal nudges /
/// Reconnect), each opening the thread with a pre-fired suggestion. Empty state
/// when clear; a lazy notification-opt-in nudge after the first real sync.
struct TodayView: View {
    @EnvironmentObject var model: AppModel

    @AppStorage("winBackDismissed") private var winBackDismissed = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.xl) {
                header
                SetupChecklistCard()
                KeyPeopleCard()
                winBackCard
                // The proactive brain's suggestions lead the day (reach out / hold
                // back / a gesture). Self-hides when the brain is off or quiet.
                BrainSuggestionsSection()
                // Due follow-ups are asks YOU armed — they must show even when the
                // reply queue is empty (otherwise "You're clear" contradicts the
                // header's "N follow-ups came due"). Renders nothing when none.
                followupLane
                if model.queue.isEmpty {
                    if model.syncing && model.dueFollowups.isEmpty && model.brainFeed.isEmpty {
                        EmptyStateView(icon: "arrow.triangle.2.circlepath",
                                       title: "Catching up…",
                                       message: "Osmo is syncing your conversations.")
                    } else if model.dueFollowups.isEmpty && model.brainFeed.isEmpty {
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
                    }
                } else {
                    notificationNudge
                    ForEach(groups, id: \.title) { group in
                        section(group.title, kind: group.kind, cards: group.cards)
                    }
                }
            }
            .padding(DS.Space.xl)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    /// A gentle win-back for someone whose trial lapsed — dismissible, once.
    @ViewBuilder private var winBackCard: some View {
        if model.trialLapsed && !winBackDismissed {
            Card {
                HStack(spacing: DS.Space.m) {
                    Image(systemName: "sparkles").font(.system(size: 16)).foregroundStyle(DS.Colors.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Miss unlimited drafts?").font(DS.Typography.bodyEm).foregroundStyle(DS.Colors.ink)
                        Text("Your trial ended — pick up Pro anytime to unlock the Read, autodraft, and more.")
                            .font(DS.Typography.caption).foregroundStyle(DS.Colors.muted)
                    }
                    Spacer()
                    PillButton("See plans") { model.present(.account) }
                    Button { winBackDismissed = true } label: {
                        Image(systemName: "xmark").font(.system(size: 10, weight: .medium))
                            .frame(width: 24, height: 24).contentShape(Rectangle())
                    }.buttonStyle(.plain).foregroundStyle(DS.Colors.muted)
                        .accessibilityLabel("Dismiss")
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            Eyebrow(greeting)
            Text("Today").font(DS.Typography.display).foregroundStyle(DS.Colors.ink)
            if model.newInbound24h > 0 || model.activeThreads7d > 0 {
                Text("You've got \(model.newInbound24h) new message\(model.newInbound24h == 1 ? "" : "s") and \(model.activeThreads7d) active conversation\(model.activeThreads7d == 1 ? "" : "s").")
                    .font(DS.Typography.body).foregroundStyle(DS.Colors.ink.opacity(0.75))
            }
            if let briefing {
                Text(briefing).font(DS.Typography.body).foregroundStyle(DS.Colors.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            AskOsmoBox()
                .padding(.top, DS.Space.s)
        }
    }

    /// The morning briefing, one honest sentence: what needs you first, computed
    /// locally — no model call, no waiting.
    private var briefing: String? {
        let byKind = Dictionary(grouping: model.queue, by: \.kind)
        var parts: [String] = []
        if let r = byKind[.reply], !r.isEmpty {
            let names = r.prefix(2).map(\.personName).joined(separator: " and ")
            parts.append("\(r.count == 1 ? names + " is" : "\(r.count) people are") waiting on you\(r.count > 1 ? " — \(names) first" : "")")
        }
        if !model.dueFollowups.isEmpty {
            parts.append("\(model.dueFollowups.count) follow-up\(model.dueFollowups.count == 1 ? "" : "s") came due")
        }
        if let n = byKind[.goalNudge]?.count, n > 0 {
            parts.append("\(n) worth a nudge toward your goals")
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " · ") + "."
    }

    @ViewBuilder private var notificationNudge: some View {
        if !model.notifier.authorized {
            Card {
                HStack(spacing: DS.Space.m) {
                    Image(systemName: "bell.badge").font(.system(size: 16)).foregroundStyle(DS.Colors.accent)
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

    /// Armed "nudge me if no reply" reminders that just came due — the top of
    /// the ritual: these are asks YOU made of Osmo.
    @ViewBuilder private var followupLane: some View {
        if !model.dueFollowups.isEmpty {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                Eyebrow("Follow-ups due — still no reply")
                ForEach(model.dueFollowups, id: \.threadID) { f in
                    FollowupRow(followup: f)
                }
            }
        }
    }

    /// One section = a hairline-grouped list of rows inside a single rounded
    /// container (the ConnectionsView idiom). Insight lines are resolved + deduped
    /// in order here, so no two rows repeat the same canned read.
    private func section(_ title: String, kind: QueueCard.Kind, cards: [QueueCard]) -> some View {
        var shown = Set<String>()
        var insightFor: [UUID: String] = [:]
        for card in cards {
            if let line = resolvedInsight(for: card), shown.insert(line).inserted {
                insightFor[card.threadID] = line
            }
        }
        return VStack(alignment: .leading, spacing: DS.Space.s) {
            Eyebrow(title)
            VStack(spacing: 0) {
                ForEach(cards) { card in
                    QueueCardRow(card: card, showsVerdict: kind != .reply,
                                 insight: insightFor[card.threadID])
                }
            }
            .background(DS.Colors.card.opacity(0.5),
                        in: RoundedRectangle(cornerRadius: DS.Radius.xl, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.xl, style: .continuous)
                .stroke(DS.Colors.hairline, lineWidth: 1))
            // NB: no container-level accessibilityIdentifier here — it collapses
            // the child rows (and their queue.card.<slug> ids) out of the AX
            // tree. The per-row ids are the stable handles instead.
        }
    }

    /// The insight line a card should show (before section-level dedupe): an open
    /// question they asked, else the live/cached AI brief, else the deterministic
    /// goal/memory/trend line. `openQuestion` is a Bool, so "what they asked" is
    /// the cleaned last inbound text (the deterministic signal that set it).
    private func resolvedInsight(for card: QueueCard) -> String? {
        let intel = model.intel(forThread: card.threadID)
        if intel.openQuestion == true,
           let q = model.queueRowMeta[card.threadID]?.lastInboundQuestion {
            return "They asked: “\(q)”"
        }
        if let brief = model.insightByThread[card.threadID], !brief.isEmpty { return brief }
        return model.insightLine(forThread: card.threadID)
    }

    private var groups: [(title: String, kind: QueueCard.Kind, cards: [QueueCard])] {
        let byKind = Dictionary(grouping: model.queue, by: \.kind)
        var out: [(String, QueueCard.Kind, [QueueCard])] = []
        // The pitch's morning ritual, in its words: owe / gone quiet / worth a nudge.
        if let r = byKind[.reply] { out.append(("You owe a reply", .reply, r)) }
        if let r = byKind[.leftOnRead] { out.append(("Gone quiet on you", .leftOnRead, r)) }
        if let r = byKind[.goalNudge] { out.append(("Worth a nudge", .goalNudge, r)) }
        if let r = byKind[.reconnect] { out.append(("Drifting — reconnect", .reconnect, r)) }
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
/// A transparent hairline row (ConnectionsView idiom): avatar · name + platform
/// logo + priority · one-line snippet · deduped insight · hover-to-draft.
struct QueueCardRow: View {
    @EnvironmentObject var model: AppModel
    let card: QueueCard
    /// Reply cards drop the verdict chip (the section header already says "you
    /// owe a reply"); the other kinds keep it since their headline varies.
    var showsVerdict: Bool = false
    /// The section-resolved, deduped insight line (nil = show nothing).
    var insight: String?
    @State private var hovering = false

    var body: some View {
        Button { openThread() } label: {
            HStack(alignment: .top, spacing: DS.Space.m) {
                if card.isGroup {
                    // A group is a place, not a person — never wear one member's
                    // face. Mirrors the Inbox's group treatment at queue size.
                    ZStack {
                        Circle().fill(DS.Colors.ink.opacity(0.06))
                        Image(systemName: "person.2.fill")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(DS.Colors.muted)
                    }
                    .frame(width: 32, height: 32)
                    .accessibilityLabel("Group conversation")
                } else {
                    AvatarView(name: card.personName,
                               data: model.avatarData(forPerson: card.personID), size: 32)
                }
                VStack(alignment: .leading, spacing: 4) {
                    header
                    snippetLine
                    if let insight { insightRule(insight) }
                    followUpOneTap
                }
                Spacer(minLength: DS.Space.s)
                trailing
            }
            .padding(.vertical, DS.Space.m)
            .padding(.horizontal, DS.Space.l)
            .background(hovering ? DS.Colors.ink.opacity(0.03) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) {
            Rectangle().fill(DS.Colors.hairlineSoft).frame(height: 1)
        }
        .onHover { hovering = $0 }
        .accessibilityIdentifier("queue.card.\(slug)")
        .task { model.ensureIntel(forThread: card.threadID) }
    }

    private var header: some View {
        HStack(spacing: DS.Space.s) {
            Text(card.personName).font(DS.Typography.bodyEm).foregroundStyle(DS.Colors.ink)
                .lineLimit(1).layoutPriority(1)
            PlatformLogo(card.platform, size: 14)
            if showsVerdict { verdictChip }
            urgencyChip
            if model.isHighPriority(card.threadID) {
                Label("Priority", systemImage: "flame.fill")
                    .font(DS.Typography.eyebrow)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .foregroundStyle(DS.Colors.red)
                    .background(DS.Colors.red.opacity(0.10), in: Capsule())
            }
            if draftReady {
                Image(systemName: "sparkles").font(.system(size: 11)).foregroundStyle(DS.Colors.accent)
            }
            Spacer(minLength: DS.Space.s)
            if let when = relativeTime {
                Text(when).font(DS.Typography.caption).foregroundStyle(DS.Colors.muted)
            }
        }
    }

    /// One-line last-message preview, cleaned; "You: " when it's yours.
    @ViewBuilder private var snippetLine: some View {
        if let snippet = model.queueRowMeta[card.threadID]?.snippet {
            Text(snippet)
                .font(DS.Typography.caption).foregroundStyle(DS.Colors.ink.opacity(0.75))
                .lineLimit(1)
        }
    }

    private func insightRule(_ text: String) -> some View {
        HStack(alignment: .top, spacing: DS.Space.s) {
            Rectangle().fill(DS.Colors.accent.opacity(0.4)).frame(width: 2)
            Text(text).font(DS.Typography.caption).italic().foregroundStyle(DS.Colors.muted)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The Draft pill is ALWAYS laid out (so hover never shifts the row and the
    /// button stays keyboard/AX-reachable); hover just cross-fades it with the
    /// idle chevron. Return on the focused row still opens the thread — the row
    /// itself is the Button.
    private var trailing: some View {
        PillButton("Draft") { openThread() }
            .accessibilityIdentifier("queue.card.draft.\(slug)")
            .opacity(hovering ? 1 : 0)
            .overlay {
                Image(systemName: "chevron.right").font(.system(size: 11))
                    .foregroundStyle(DS.Colors.muted)
                    .opacity(hovering ? 0 : 1)
                    .allowsHitTesting(false)
            }
            .animation(DS.Motion.standard, value: hovering)
    }

    /// Deterministic AX slug: lowercased first name + the first 4 chars of the
    /// thread UUID — two "Amy"s must never collide on `queue.card.amy`. The
    /// probe matches on the `queue.card.<name>` PREFIX.
    private var slug: String {
        let first = card.personName.split(separator: " ").first.map(String.init) ?? "x"
        let cleaned = first.lowercased().filter { $0.isLetter || $0.isNumber }
        let suffix = card.threadID.uuidString.prefix(4).lowercased()
        return "\(cleaned.isEmpty ? "x" : cleaned)-\(suffix)"
    }

    private var relativeTime: String? {
        model.queueRowMeta[card.threadID]?.when
    }

    /// Today/overdue only — `.soon` doesn't earn a card-level chip (the flame
    /// above already signals general priority; this reserves red/amber for
    /// what's genuinely pressing).
    @ViewBuilder private var urgencyChip: some View {
        let urgency = model.intel(forThread: card.threadID).urgency
        if urgency == .today || urgency == .overdue {
            IntelChip(kind: .urgency(urgency!, reason: model.intel(forThread: card.threadID).urgencyReason))
        }
    }

    /// True once an autodraft has actually landed for this thread (isAuto is
    /// only ever set true by the autodraft path — a user save always clears it).
    private var draftReady: Bool {
        model.queueRowMeta[card.threadID]?.draftReady == true
    }

    /// One tap to arm the same "nudge if no reply" reminder the thread's
    /// deterministic deadline read implies — skipped once a reminder is already
    /// pending or due, so this never offers to arm what's already armed.
    @ViewBuilder private var followUpOneTap: some View {
        if let due = model.suggestedFollowUpBy(forThread: card.threadID),
           !model.pendingFollowups.contains(where: { $0.threadID == card.threadID }),
           !model.dueFollowups.contains(where: { $0.threadID == card.threadID }) {
            // A high-priority tap so arming the reminder reliably wins over the
            // enclosing row Button (nested plain Buttons have ambiguous hit-testing;
            // the row's action is "open thread", this one is "arm follow-up").
            Label("Follow up by \(Self.followUpLabel(due))", systemImage: "bell")
                .font(DS.Typography.eyebrow)
                .foregroundStyle(DS.Colors.accent)
                .contentShape(Rectangle())
                .highPriorityGesture(TapGesture().onEnded {
                    model.armFollowup(thread: card.threadID, after: due.timeIntervalSinceNow)
                })
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel("Arm a follow-up reminder")
        }
    }

    /// Weekday within the week ("Wed"); month + day once it's further out, so a
    /// far date isn't ambiguous about which week.
    static func followUpLabel(_ due: Date) -> String {
        let days = due.timeIntervalSinceNow / 86_400
        let f = DateFormatter()
        f.dateFormat = days > 6 ? "MMM d" : "EEE"
        return f.string(from: due)
    }

    /// The explicit timing call, right on the card — nudge or lay back.
    private var verdict: ReachOutVerdict { model.reachOutVerdict(forThread: card.threadID) }

    private var verdictChip: some View {
        let hot = verdict.kind == .goodTime || verdict.kind == .yourTurn
        return Text(verdict.headline)
            .font(DS.Typography.eyebrow)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .foregroundStyle(hot ? DS.Colors.accent : DS.Colors.muted)
            .background((hot ? DS.Colors.accent : DS.Colors.muted).opacity(0.12), in: Capsule())
    }

    private func openThread() {
        model.focusedThreadID = card.threadID
        model.section = .inbox
        model.selectedThreadID = card.threadID
    }
}

/// A due follow-up: person + how long overdue, one tap to draft the nudge, one
/// to let it go (clear the reminder).
struct FollowupRow: View {
    @EnvironmentObject var model: AppModel
    let followup: ThreadFollowup

    var body: some View {
        Card {
            HStack(spacing: DS.Space.m) {
                Image(systemName: "bell.badge").font(.system(size: 14)).foregroundStyle(DS.Colors.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(DS.Typography.bodyEm).foregroundStyle(DS.Colors.ink).lineLimit(1)
                    Text("You asked to be nudged if they didn't reply — they haven't.")
                        .font(DS.Typography.caption).foregroundStyle(DS.Colors.muted)
                }
                Spacer()
                Button("Let it go") {
                    try? model.store.clearFollowup(thread: followup.threadID)
                    model.reload()
                }
                .font(DS.Typography.captionEm).buttonStyle(.plain).foregroundStyle(DS.Colors.muted)
                PillButton("Draft the nudge") {
                    model.focusedThreadID = followup.threadID
                    model.section = .inbox
                    model.selectedThreadID = followup.threadID
                }
            }
        }
    }

    private var title: String {
        guard let thread = try? model.store.thread(id: followup.threadID) else { return "Conversation" }
        let members = (try? model.store.contacts(inThread: thread.id)) ?? []
        return threadTitle(thread, members: members)
    }
}

/// "Ask Osmo" — a grounded local Q&A chat. Answers come only from the user's own
/// messages + people directory. A real chat surface: right-aligned questions,
/// orb-avatared answers, an animated thinking indicator, and suggested prompts
/// on the empty state. Session-scoped (clears on relaunch).
struct AskOsmoBox: View {
    @EnvironmentObject var model: AppModel
    @State private var question = ""
    @State private var pending: String?        // the just-asked question, shown while busy
    @FocusState private var focused: Bool

    /// A few grounded starters — the last one references a real recent person so
    /// the suggestion feels personal, not canned.
    private var suggestions: [String] {
        var s = ["Who's waiting on me?", "Who am I overdue to reach out to?"]
        if let name = model.people.first?.name.split(separator: " ").first.map(String.init) {
            s.append("What did \(name) and I last talk about?")
        } else {
            s.append("Summarize what's happened this week")
        }
        return s
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            if model.askExchanges.isEmpty && pending == nil {
                emptyState
            } else {
                transcript
            }
            inputBar
        }
        .padding(DS.Space.m)
        .background(DS.Colors.card.opacity(0.55),
                    in: RoundedRectangle(cornerRadius: DS.Radius.xl, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.xl, style: .continuous)
            .stroke(DS.Colors.hairline, lineWidth: 1))
        .animation(DS.Motion.standard, value: model.askExchanges.count)
        .animation(DS.Motion.standard, value: pending)
        .onChange(of: model.askBusy) { _, busy in if !busy { pending = nil } }
        // Belt-and-braces for the coalesced-transition case above: the answer
        // landing is just as authoritative a "done" signal as askBusy flipping.
        .onChange(of: model.askExchanges.count) { _, _ in pending = nil }
    }

    // MARK: Empty state

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack(spacing: DS.Space.s) {
                AskOrb(mode: .idle, size: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Ask Osmo").font(DS.Typography.bodyEm).foregroundStyle(DS.Colors.ink)
                    Text("About your conversations and people — answered from what's on your Mac.")
                        .font(DS.Typography.caption).foregroundStyle(DS.Colors.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(suggestions, id: \.self) { s in
                    Button { ask(s) } label: {
                        HStack(spacing: DS.Space.s) {
                            Image(systemName: "sparkle").font(.system(size: 10)).foregroundStyle(DS.Colors.accent)
                            Text(s).font(DS.Typography.caption).foregroundStyle(DS.Colors.ink)
                            Spacer(minLength: 0)
                            Image(systemName: "arrow.up.right").font(.system(size: 9)).foregroundStyle(DS.Colors.muted)
                        }
                        .padding(.horizontal, DS.Space.s).padding(.vertical, 7)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(DS.Colors.paper, in: RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous)
                            .stroke(DS.Colors.hairlineSoft, lineWidth: 1))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: Transcript

    private var transcript: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            ForEach(Array(model.askExchanges.enumerated()), id: \.offset) { _, ex in
                userBubble(ex.q)
                answerRow(ex.a, isError: ex.isError)
                if !ex.actions.isEmpty { actionChips(ex.actions) }
            }
            // Gated on askBusy (the truth), not just the `pending` latch: with an
            // instant (mock) answer, askBusy flips true→false inside one runloop
            // turn, SwiftUI coalesces the transition, and the .onChange that
            // clears `pending` never fires — leaving a PERMANENT thinking row
            // whose 30fps orb + repeatForever dots relayout the whole window
            // every frame (measured ~46% of main-thread time, starving AX).
            if let pending, model.askBusy {
                userBubble(pending)
                thinkingRow
            }
        }
    }

    /// The chat DOES things: chips parsed from the answer, each landing in a
    /// real app function (open/draft the thread, arm a reminder, snooze).
    private func actionChips(_ actions: [AskAction]) -> some View {
        HStack(spacing: DS.Space.s) {
            ForEach(actions) { action in
                Button { model.perform(action) } label: {
                    HStack(spacing: 4) {
                        Image(systemName: icon(for: action.kind)).font(.system(size: 10, weight: .medium))
                        Text(label(for: action)).font(DS.Typography.captionEm)
                    }
                    .padding(.horizontal, DS.Space.s).padding(.vertical, 5)
                    .background(DS.Colors.accent.opacity(0.10), in: Capsule())
                    .overlay(Capsule().stroke(DS.Colors.accent.opacity(0.35), lineWidth: 1))
                    .foregroundStyle(DS.Colors.accent)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("ask.action.\(action.kind.rawValue)")
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 28)   // aligns under the answer text, past the orb
    }

    private func icon(for kind: AskAction.Kind) -> String {
        switch kind {
        case .draft: "square.and.pencil"
        case .open: "bubble.left.and.bubble.right"
        case .remind: "bell.badge"
        case .snooze: "moon.zzz"
        }
    }

    private func label(for action: AskAction) -> String {
        let first = action.person.split(separator: " ").first.map(String.init) ?? action.person
        switch action.kind {
        case .draft: return "Draft reply to \(first)"
        case .open: return "Open \(first)'s thread"
        case .remind: return "Remind me in \(action.days ?? 3)d"
        case .snooze: return "Snooze \(action.days ?? 1)d"
        }
    }

    private func userBubble(_ text: String) -> some View {
        HStack {
            Spacer(minLength: 44)
            Text(text).font(DS.Typography.body).foregroundStyle(.white)
                .padding(.horizontal, DS.Space.m).padding(.vertical, DS.Space.s)
                .background(DS.Colors.accent, in: RoundedRectangle(cornerRadius: DS.Radius.l, style: .continuous))
                .textSelection(.enabled)
        }
        .transition(.move(edge: .trailing).combined(with: .opacity))
    }

    private func answerRow(_ text: String, isError: Bool = false) -> some View {
        HStack(alignment: .top, spacing: DS.Space.s) {
            // ALWAYS the static idle pose. `.thinking` runs a 30fps TimelineView —
            // on a persisted answer row that's a PERMANENT full-window relayout
            // storm (measured: ~44% of main-thread time, starving AX/everything).
            // An error is already signaled by the red copy + tint, not motion.
            AskOrb(mode: .idle, size: 20)
            Text(text).font(DS.Typography.body)
                .foregroundStyle(isError ? DS.Colors.red : DS.Colors.ink)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .padding(.horizontal, DS.Space.m).padding(.vertical, DS.Space.s)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(isError ? DS.Colors.red.opacity(0.06) : DS.Colors.paper,
                            in: RoundedRectangle(cornerRadius: DS.Radius.l, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.l, style: .continuous)
                    .stroke(isError ? DS.Colors.red.opacity(0.30) : DS.Colors.hairlineSoft, lineWidth: 1))
        }
        .transition(.opacity)
        .accessibilityIdentifier("ask.answer")
    }

    private var thinkingRow: some View {
        HStack(alignment: .center, spacing: DS.Space.s) {
            AskOrb(mode: .thinking, size: 20)
            AskThinkingDots()
                .padding(.horizontal, DS.Space.m).padding(.vertical, DS.Space.s + 3)
                .background(DS.Colors.paper, in: RoundedRectangle(cornerRadius: DS.Radius.l, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.l, style: .continuous)
                    .stroke(DS.Colors.hairlineSoft, lineWidth: 1))
            Spacer(minLength: 0)
        }
        .transition(.opacity)
    }

    // MARK: Input

    private var inputBar: some View {
        HStack(spacing: DS.Space.s) {
            TextField("Ask about your conversations or contacts…", text: $question)
                .textFieldStyle(.plain).font(DS.Typography.body).focused($focused)
                .onSubmit { ask(question) }
                .accessibilityIdentifier("ask.input")
            if canSend {
                Button { ask(question) } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 18))
                }.buttonStyle(.plain).foregroundStyle(DS.Colors.accent)
                    .transition(.scale.combined(with: .opacity))
                    .accessibilityIdentifier("ask.send")
            }
        }
        .padding(.horizontal, DS.Space.m).padding(.vertical, DS.Space.s)
        .background(DS.Colors.paper, in: Capsule())
        .overlay(Capsule().stroke(canSend ? DS.Colors.accent.opacity(0.5) : DS.Colors.hairline, lineWidth: 1))
        .animation(DS.Motion.standard, value: canSend)
    }

    private var canSend: Bool {
        !model.askBusy && !question.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func ask(_ text: String) {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !model.askBusy else { return }
        pending = q
        model.askOsmo(q)
        question = ""
    }
}

/// A three-dot "typing" indicator — the classic chat thinking animation, staggered.
struct AskThinkingDots: View {
    @State private var animating = false
    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { i in
                Circle().fill(DS.Colors.muted)
                    .frame(width: 6, height: 6)
                    .opacity(animating ? 1 : 0.3)
                    .scaleEffect(animating ? 1 : 0.7)
                    .animation(.easeInOut(duration: 0.6).repeatForever().delay(Double(i) * 0.18),
                               value: animating)
            }
        }
        .onAppear { animating = true }
        .accessibilityLabel("Osmo is thinking")
    }
}

/// Post-onboarding "get set up" checklist — shows until every step is done or the
/// user dismisses it. Each unfinished row jumps to the action.
struct SetupChecklistCard: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("setupChecklistDismissed") private var dismissed = false

    private var connected: Bool { model.connections.phases.values.contains { $0.isActive } }
    private var items: [(label: String, done: Bool, act: () -> Void)] {
        [
            ("Sign in to save your account", model.account.isSignedIn, { model.present(.account) }),
            ("Connect a platform", connected, { model.section = .connections }),
            ("Grant Accessibility for the pill", AXPermission.isTrusted, { AXPermission.promptIfNeeded() }),
            ("Turn on reply reminders", model.notifier.authorized, { Task { await model.notifier.requestAuthorization() } }),
        ]
    }

    var body: some View {
        let done = items.filter(\.done).count
        if !dismissed && done < items.count {
            Card {
                VStack(alignment: .leading, spacing: DS.Space.s) {
                    HStack {
                        Text("Get the most out of Osmo").font(DS.Typography.bodyEm).foregroundStyle(DS.Colors.ink)
                        Spacer()
                        Text("\(done)/\(items.count)").font(DS.Typography.caption).foregroundStyle(DS.Colors.muted)
                        Button { dismissed = true } label: {
                            Image(systemName: "xmark").font(.system(size: 10, weight: .medium))
                                .frame(width: 24, height: 24).contentShape(Rectangle())
                        }.buttonStyle(.plain).foregroundStyle(DS.Colors.muted)
                            .accessibilityLabel("Dismiss checklist")
                    }
                    ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                        Button(action: item.act) {
                            HStack(spacing: DS.Space.s) {
                                Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(item.done ? DS.Colors.green : DS.Colors.muted)
                                Text(item.label).font(DS.Typography.body)
                                    .foregroundStyle(item.done ? DS.Colors.muted : DS.Colors.ink)
                                    .strikethrough(item.done)
                                Spacer()
                                if !item.done {
                                    Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(DS.Colors.muted)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).disabled(item.done)
                    }
                }
            }
        }
    }
}

/// After the first sync, let the user flag who matters most — picked from REAL
/// synced people (not free text). Feeds `onboardingProfile.keyPeople` → prompts.
struct KeyPeopleCard: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("keyPeopleAsked") private var asked = false
    // Keyed by stable person id, not display name — two synced contacts can share
    // a name and would otherwise toggle/collapse as one.
    @State private var selected: Set<UUID> = []

    var body: some View {
        let candidates = Array(model.people.prefix(12))
        if !asked, model.onboardingProfile.keyPeople.isEmpty, !candidates.isEmpty {
            Card {
                VStack(alignment: .leading, spacing: DS.Space.s) {
                    Text("Who matters most?").font(DS.Typography.bodyEm).foregroundStyle(DS.Colors.ink)
                    Text("Pick a few — Osmo prioritizes them and tailors your drafts. Straight from your real conversations.")
                        .font(DS.Typography.caption).foregroundStyle(DS.Colors.muted)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 6)], alignment: .leading, spacing: 6) {
                        ForEach(candidates) { p in
                            let on = selected.contains(p.id)
                            Button {
                                if on { selected.remove(p.id) } else { selected.insert(p.id) }
                            } label: {
                                HStack(spacing: 5) {
                                    AvatarView(name: p.name, data: p.avatar, size: 18)
                                    Text(p.name).font(DS.Typography.caption).foregroundStyle(DS.Colors.ink).lineLimit(1)
                                    if on { Image(systemName: "checkmark").font(.system(size: 8, weight: .bold)).foregroundStyle(DS.Colors.accent) }
                                }
                                .padding(.horizontal, 8).padding(.vertical, 5)
                                .background(on ? DS.Colors.accent.opacity(0.12) : DS.Colors.card, in: Capsule())
                                .overlay(Capsule().stroke(on ? DS.Colors.accent.opacity(0.5) : DS.Colors.hairline, lineWidth: 1))
                                .contentShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    HStack {
                        Button("Not now") { asked = true }
                            .buttonStyle(.plain).font(DS.Typography.captionEm).foregroundStyle(DS.Colors.muted)
                        Spacer()
                        PillButton(selected.isEmpty ? "Save" : "Save \(selected.count)", kind: .quiet) {
                            model.onboardingProfile.keyPeople = candidates.filter { selected.contains($0.id) }.map(\.name)
                            asked = true
                        }.disabled(selected.isEmpty)
                    }
                }
            }
        }
    }
}
