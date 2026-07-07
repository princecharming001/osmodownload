import SwiftUI
import OsmoCore
import OsmoBrain
import OsmoShell

/// Unified cross-platform inbox: a thread list + a detail with transcript,
/// compose bar, and the "Draft with Osmo" strip. A chip row filters the list
/// to one platform (only platforms that actually have threads are offered).
struct InboxView: View {
    @EnvironmentObject var model: AppModel
    @State private var showFilterPanel = false
    private var platformFilter: Platform? { model.inboxPlatformFilter }

    var body: some View {
        HSplitView {
            threadList
                .frame(minWidth: 260, maxWidth: 340)
            detail
                .frame(maxWidth: .infinity)
        }
    }

    private var threadList: some View {
        VStack(spacing: 0) {
            if !presentPlatforms.isEmpty || model.hiddenNonHumanCount > 0 {
                filterBar
                HairlineDivider()
            }
            Group {
                if model.threads.isEmpty {
                    EmptyStateView(icon: "tray", title: "No conversations yet",
                                   message: "Connect a platform and Osmo pulls your threads here.",
                                   cta: ("Connect", { model.section = .connections }))
                } else if filteredThreads.isEmpty {
                    EmptyStateView(icon: "line.3.horizontal.decrease.circle",
                                   title: "Just people here",
                                   message: platformFilter != nil
                                       ? "No \(platformFilter!.displayName) conversations."
                                       : "Only automated messages left — use Show all to see them.")
                } else {
                    List(selection: $model.selectedThreadID) {
                        ForEach(filteredThreads) { thread in
                            ThreadRow(thread: thread).tag(thread.id)
                        }
                    }
                    .listStyle(.inset)
                }
            }
        }
        .background(DS.Colors.card)
    }

    // MARK: - Platform filter

    /// Platforms that actually have threads, in a stable order. Computed over the
    /// human-filtered set so a chip only appears when it has real conversations.
    private var presentPlatforms: [Platform] { InboxFilter.present(in: model.humanFilteredThreads) }

    private var filteredThreads: [OsmoThread] {
        InboxFilter.apply(model.inboxPlatformFilter, to: model.humanFilteredThreads)
    }

    /// Two rows, entirely custom-drawn (no native segmented control, menu, or
    /// picker) — Kinso-style fast filtering in the app's own editorial voice.
    /// Row 1: a scrollable underline tab bar for platform. Row 2: the Filter
    /// pill (opens a hand-built panel) + result count + a two-way sort pill.
    private var filterBar: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: DS.Space.l) {
                    platformTab(nil, "All")
                    ForEach(presentPlatforms, id: \.self) { platform in
                        platformTab(platform, platform.displayName)
                    }
                }
                .padding(.horizontal, DS.Space.m)
            }

            HStack(spacing: DS.Space.s) {
                filterButton
                Spacer(minLength: 0)
                Text("\(filteredThreads.count)")
                    .font(DS.Typography.caption).foregroundStyle(DS.Colors.muted)
                    .monospacedDigit()
                sortToggle
            }
            .padding(.horizontal, DS.Space.m)
        }
        .padding(.top, DS.Space.s)
        .padding(.bottom, DS.Space.xs)
    }

    /// One underline tab — plain text, an animated ink rule beneath the active
    /// one. Deliberately not a segmented control: no pill chrome, no dividers.
    private func platformTab(_ platform: Platform?, _ label: String) -> some View {
        let selected = model.inboxPlatformFilter == platform
        return Button {
            withAnimation(DS.Motion.standard) { model.inboxPlatformFilter = platform }
        } label: {
            VStack(spacing: 5) {
                Text(label)
                    .font(selected ? DS.Typography.captionEm : DS.Typography.caption)
                    .foregroundStyle(selected ? DS.Colors.ink : DS.Colors.muted)
                Rectangle()
                    .fill(selected ? DS.Colors.ink : Color.clear)
                    .frame(height: 2)
            }
        }
        .buttonStyle(.plain)
    }

    /// The filter pill — fills solid when anything's active, opens the panel.
    private var filterButton: some View {
        Button { showFilterPanel.toggle() } label: {
            HStack(spacing: 5) {
                Image(systemName: "line.3.horizontal.decrease").font(.system(size: 10, weight: .semibold))
                Text(activeFilterCount > 0 ? "Filter · \(activeFilterCount)" : "Filter")
                    .font(DS.Typography.captionEm)
            }
            .padding(.horizontal, DS.Space.m).padding(.vertical, 6)
            .foregroundStyle(activeFilterCount > 0 ? .white : DS.Colors.ink)
            .background(activeFilterCount > 0 ? DS.Colors.ink : DS.Colors.chip, in: Capsule())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showFilterPanel, arrowEdge: .bottom) { filterPanel }
    }

    /// Hand-built filter panel: custom checkbox rows + a topic chip grid,
    /// nothing borrowed from AppKit's Menu/Toggle chrome.
    private var filterPanel: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            Text("Filter").font(DS.Typography.bodyEm).foregroundStyle(DS.Colors.ink)
            VStack(alignment: .leading, spacing: DS.Space.m) {
                filterCheckRow("Unanswered only", isOn: $model.unansweredOnly)
                filterCheckRow("Show automated (\(model.hiddenNonHumanCount) hidden)", isOn: $model.showNonHuman)
            }
            if !model.presentUrgencies.isEmpty {
                HairlineDivider()
                Text("URGENCY").font(DS.Typography.eyebrow).tracking(0.6).foregroundStyle(DS.Colors.muted)
                FlowLayout(spacing: 6) {
                    ForEach(model.presentUrgencies, id: \.self) { urgencyOption($0) }
                }
            }
            if !model.presentActions.isEmpty {
                HairlineDivider()
                Text("ACTION").font(DS.Typography.eyebrow).tracking(0.6).foregroundStyle(DS.Colors.muted)
                FlowLayout(spacing: 6) {
                    ForEach(model.presentActions, id: \.self) { actionOption($0) }
                }
            }
            if !model.presentTopics.isEmpty {
                HairlineDivider()
                Text("TOPIC").font(DS.Typography.eyebrow).tracking(0.6).foregroundStyle(DS.Colors.muted)
                FlowLayout(spacing: 6) {
                    ForEach(model.presentTopics, id: \.self) { topicOption($0) }
                }
            }
            if activeFilterCount > 0 {
                HairlineDivider()
                Button("Clear filters") {
                    withAnimation(DS.Motion.standard) {
                        model.unansweredOnly = false
                        model.topicFilter = nil
                        model.showNonHuman = false
                        model.urgencyFilter = nil
                        model.actionFilter = nil
                    }
                }
                .font(DS.Typography.captionEm).buttonStyle(.plain).foregroundStyle(DS.Colors.accent)
            }
        }
        .padding(DS.Space.l)
        .frame(width: 300)
    }

    private func urgencyOption(_ level: IntelUrgency) -> some View {
        let selected = model.urgencyFilter == level
        return Button {
            withAnimation(DS.Motion.standard) { model.urgencyFilter = selected ? nil : level }
        } label: {
            IntelChip(kind: .urgency(level, reason: nil))
                .opacity(selected ? 1 : 0.55)
        }
        .buttonStyle(.plain)
    }

    private func actionOption(_ kind: IntelAction) -> some View {
        let selected = model.actionFilter == kind
        return Button {
            withAnimation(DS.Motion.standard) { model.actionFilter = selected ? nil : kind }
        } label: {
            IntelChip(kind: .action(kind))
                .opacity(selected ? 1 : 0.55)
        }
        .buttonStyle(.plain)
    }

    private func filterCheckRow(_ label: String, isOn: Binding<Bool>) -> some View {
        Button {
            withAnimation(DS.Motion.standard) { isOn.wrappedValue.toggle() }
        } label: {
            HStack(spacing: DS.Space.s) {
                ZStack {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(isOn.wrappedValue ? DS.Colors.ink : Color.clear)
                        .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .strokeBorder(isOn.wrappedValue ? Color.clear : DS.Colors.hairline, lineWidth: 1.5))
                        .frame(width: 16, height: 16)
                    if isOn.wrappedValue {
                        Image(systemName: "checkmark").font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
                Text(label).font(DS.Typography.body).foregroundStyle(DS.Colors.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
        }
        .buttonStyle(.plain)
    }

    private func topicOption(_ topic: String) -> some View {
        let selected = model.topicFilter == topic
        let color = TopicChip.color(for: topic)
        return Button {
            withAnimation(DS.Motion.standard) { model.topicFilter = selected ? nil : topic }
        } label: {
            Text(topic)
                .font(DS.Typography.eyebrow)
                .lineLimit(1)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .foregroundStyle(selected ? .white : color)
                .background(selected ? color : color.opacity(0.12), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    /// Two icon pills sharing one capsule track — recency vs. attention-priority.
    private var sortToggle: some View {
        HStack(spacing: 2) {
            sortOption(.recent, "clock", help: "Sort by recency")
            sortOption(.priority, "flame", help: "Sort by who needs your attention first")
        }
        .padding(3)
        .background(DS.Colors.chip, in: Capsule())
    }

    private func sortOption(_ sort: AppModel.InboxSort, _ icon: String, help: String) -> some View {
        let selected = model.inboxSort == sort
        return Button {
            withAnimation(DS.Motion.standard) { model.inboxSort = sort }
        } label: {
            Image(systemName: icon).font(.system(size: 11, weight: .semibold))
                .frame(width: 26, height: 20)
                .foregroundStyle(selected ? .white : DS.Colors.muted)
                .background(selected ? DS.Colors.ink : Color.clear, in: Capsule())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var activeFilterCount: Int {
        (model.unansweredOnly ? 1 : 0) + (model.topicFilter != nil ? 1 : 0) + (model.showNonHuman ? 1 : 0)
            + (model.urgencyFilter != nil ? 1 : 0) + (model.actionFilter != nil ? 1 : 0)
    }

    @ViewBuilder private var detail: some View {
        if let threadID = model.selectedThreadID {
            ThreadDetailView(threadID: threadID)
                .id(threadID)
        } else {
            EmptyStateView(icon: "bubble.left.and.bubble.right",
                           title: "Pick a conversation",
                           message: "Select a thread to see the transcript and draft a reply.")
        }
    }
}

/// A human title for a thread: an explicit chat name, else the group's members
/// ("Alex, Jordan, Sam +2"), else the single 1:1 contact. Shared by the row,
/// the detail header, and partnerName so they never drift.
func threadTitle(_ thread: OsmoThread, members: [OsmoContact]) -> String {
    if let t = thread.title, !t.isEmpty { return t }
    let others = members.filter { !$0.isMe }
    if thread.isGroup {
        guard !others.isEmpty else { return "Group" }
        let names = others.prefix(3).map(\.displayLabel).joined(separator: ", ")
        return others.count > 3 ? "\(names) +\(others.count - 3)" : names
    }
    return others.first?.displayLabel ?? members.first?.displayLabel ?? "New conversation"
}

/// A single, readable preview line — never blank, never a raw control-char blob,
/// and clamped so an odd platform payload can't garble the list. A genuinely
/// empty thread reads "No messages yet"; an attachment-only message (real
/// message, no text) reads "Attachment" — the two must never collapse into
/// the same string, or a photo/video thread looks like it has no messages.
func previewLine(_ message: OsmoMessage?) -> String {
    guard let message else { return "No messages yet" }
    guard !message.text.isEmpty else { return "Attachment" }
    let flattened = message.text
        .replacingOccurrences(of: "\n", with: " ")
        .replacingOccurrences(of: "\r", with: " ")
        .components(separatedBy: .controlCharacters).joined(separator: " ")
        .trimmingCharacters(in: .whitespaces)
    if flattened.isEmpty { return "Attachment" }
    return flattened.count > 90 ? String(flattened.prefix(90)) + "…" : flattened
}

/// Like `previewLine`, but names an attachment-only message by its media kind
/// instead of the generic "Attachment" — "Photo"/"Video"/"Voice message"/the
/// filename/the link's title.
func previewLine(_ message: OsmoMessage?, attachments: [OsmoAttachment]) -> String {
    let base = previewLine(message)
    guard base == "Attachment", let first = attachments.first else { return base }
    switch first.kind {
    case .image: return "Photo"
    case .video: return "Video"
    case .audio: return "Voice message"
    case .file: return first.filename ?? "File"
    case .link: return first.title ?? "Shared post"
    }
}

struct ThreadRow: View {
    @EnvironmentObject var model: AppModel
    let thread: OsmoThread

    var body: some View {
        HStack(spacing: DS.Space.m) {
            avatarCluster
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: DS.Space.xs) {
                    Text(title).font(DS.Typography.bodyEm).foregroundStyle(DS.Colors.ink).lineLimit(1)
                    if thread.isGroup {
                        Image(systemName: "person.2.fill")
                            .font(.system(size: 8)).foregroundStyle(DS.Colors.muted)
                    }
                    Image(systemName: thread.platform.symbolName)
                        .font(.system(size: 9)).foregroundStyle(thread.platform.tint)
                    if hasAutodraft {
                        Image(systemName: "sparkles").font(.system(size: 9)).foregroundStyle(DS.Colors.accent)
                            .help("Osmo drafted a reply")
                    }
                }
                HStack(spacing: DS.Space.xs) {
                    intelChips
                    Text(preview).font(DS.Typography.caption).foregroundStyle(DS.Colors.muted).lineLimit(1)
                }
            }
            Spacer()
        }
        .padding(.vertical, 2)
        .task(id: intelEligible) { if intelEligible { model.ensureIntel(forThread: thread.id) } }
    }

    private var members: [OsmoContact] { (try? model.store.contacts(inThread: thread.id)) ?? [] }
    private var others: [OsmoContact] { members.filter { !$0.isMe } }
    private var title: String { threadTitle(thread, members: members) }

    /// True once an autodraft has actually landed (isAuto is only ever set true
    /// by the autodraft path — a user save always clears it).
    private var hasAutodraft: Bool {
        (try? model.store.draftRecord(forThread: thread.id))?.isAuto == true
    }

    /// Restrained by design: at most 2 chips (urgency + action). Topic only
    /// falls back in when neither applies — never all three at once.
    @ViewBuilder private var intelChips: some View {
        let merged = model.intel(forThread: thread.id)
        let showUrgency = merged.urgency != nil && merged.urgency != .none
        let showAction = merged.action.map { [.decide, .schedule, .pay].contains($0) } ?? false
        if showUrgency { IntelChip(kind: .urgency(merged.urgency!, reason: merged.urgencyReason)) }
        if showAction { IntelChip(kind: .action(merged.action!)) }
        if !showUrgency, !showAction, let topic = model.topic(forThread: thread.id) {
            TopicChip(topic: topic)
        }
    }

    /// Don't stampede the model on a 500-thread inbox — only rows that plausibly
    /// need the deeper read (owed a reply, or recently active) kick it off.
    private var intelEligible: Bool {
        let status = model.statusByThread[thread.id]
        if status == .needsReply || status == .leftOnRead { return true }
        if let last = thread.lastMessageAt { return Date().timeIntervalSince(last) <= 7 * 86_400 }
        return false
    }

    /// A single avatar for 1:1; two overlapped avatars for a group.
    @ViewBuilder private var avatarCluster: some View {
        if thread.isGroup, others.count >= 2 {
            ZStack {
                AvatarView(name: others[1].displayLabel, data: others[1].avatarData, size: 26)
                    .offset(x: 8, y: 6)
                AvatarView(name: others[0].displayLabel, data: others[0].avatarData, size: 26)
                    .offset(x: -6, y: -4)
                    .overlay(Circle().stroke(DS.Colors.card, lineWidth: 2).offset(x: -6, y: -4))
            }
            .frame(width: 36, height: 36)
        } else {
            AvatarView(name: title, data: others.first?.avatarData, size: 36)
        }
    }

    private var preview: String { previewLine(try? model.store.lastMessage(inThread: thread.id)) }
}

/// Transcript + compose + AI assist for one thread.
struct ThreadDetailView: View {
    @EnvironmentObject var model: AppModel
    let threadID: UUID

    @State private var messages: [OsmoMessage] = []
    @State private var draft: String = ""
    @State private var showAssist = false
    @State private var thread: OsmoThread?
    // Group attribution + tapbacks + replies, resolved once per load (not per bubble).
    @State private var members: [OsmoContact] = []
    @State private var contactsByID: [UUID: OsmoContact] = [:]
    @State private var reactionsByTarget: [UUID: [MessageReaction]] = [:]
    @State private var messagesByID: [UUID: OsmoMessage] = [:]
    @State private var attachmentsByMessage: [UUID: [OsmoAttachment]] = [:]
    @State private var hoveringName = false

    var body: some View {
        VStack(spacing: 0) {
            transcript
            Divider()
            if showAssist { assist }
            composeBar
        }
        .background(DS.Colors.paper)
        .onAppear { load(); model.focusedThreadID = threadID }
        // Re-read the transcript whenever the store changes — a pill send, an
        // incoming message, or a background poll — not just this view's own send.
        // load() preserves an in-progress draft (it only restores when empty).
        .onChange(of: model.dataVersion) { _, _ in load() }
        .onDisappear { saveDraft(); if model.focusedThreadID == threadID { model.focusedThreadID = nil } }
    }

    private var transcript: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                HStack {
                    partnerNameLabel
                    if let platform = thread?.platform {
                        Chip(platform.displayName, systemImage: platform.symbolName)
                    }
                    Spacer()
                    if canOpenInPlatform {
                        Button { openInPlatform() } label: {
                            Image(systemName: "arrow.up.forward.app")
                        }
                        .buttonStyle(.plain).foregroundStyle(DS.Colors.muted)
                        .help("Open this conversation in \(thread?.platform.displayName ?? "the app")")
                    }
                    Menu {
                        Section("Nudge me if no reply") {
                            Button("At their rhythm (recommended)") { model.armFollowup(thread: threadID, after: nil) }
                            Button("Tomorrow") { model.armFollowup(thread: threadID, after: 24 * 3600) }
                            Button("In 3 days") { model.armFollowup(thread: threadID, after: 3 * 86_400) }
                            if (try? model.store.followup(forThread: threadID)) != nil {
                                Button("Cancel reminder") {
                                    try? model.store.clearFollowup(thread: threadID); model.reload()
                                }
                            }
                        }
                        Section("Snooze") {
                            Button("Snooze 3 hours") { snooze(hours: 3) }
                            Button("Snooze until tomorrow") { snooze(hours: 18) }
                        }
                    } label: { Image(systemName: "clock") }
                        .menuStyle(.borderlessButton).fixedSize()
                }
                .padding(.bottom, DS.Space.s)

                // The deeper per-conversation read: urgency, the owed action,
                // an open question, promises the user made, tone, effort — a
                // restrained strip, not a wall of chips (nothing shows if the
                // thread has no opinion on any of these yet).
                intelStrip

                // Conversations that connect themselves: same person elsewhere
                // (identity graph — certain) + same topic (heuristic).
                relatedRow

                ForEach(dayGroups, id: \.day) { group in
                    // Day separator — the transcript reads like the real platform.
                    Text(dayLabel(group.day))
                        .font(DS.Typography.eyebrow).foregroundStyle(DS.Colors.muted)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, DS.Space.s)
                    ForEach(group.messages) { message in
                        let sender = message.senderContactID.flatMap { contactsByID[$0] }
                        MessageBubble(
                            message: message,
                            isGroup: thread?.isGroup ?? false,
                            senderName: sender?.displayLabel,
                            senderAvatar: sender?.avatarData,
                            reactions: reactionsByTarget[message.id] ?? [],
                            replyParent: message.inReplyToMessageID.flatMap { messagesByID[$0] },
                            replyParentSender: replyParentSender(message),
                            replyParentAttachments: message.inReplyToMessageID
                                .flatMap { attachmentsByMessage[$0] } ?? [],
                            timeText: Self.timeFormatter.string(from: message.sentAt),
                            attachments: attachmentsByMessage[message.id] ?? [],
                            onReact: message.isFromMe ? nil : { type, emoji in react(message, type: type, emoji: emoji) })
                    }
                }
            }
            .padding(DS.Space.l)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The conversation's counterpart, resolved to a person the People roster
    /// already knows (via `buildPeople`'s `personID ?? threadID` key) — nil
    /// when there's genuinely nothing to navigate to.
    private var navigablePersonID: UUID? {
        let candidate = members.first(where: { !$0.isMe })?.personID ?? threadID
        return model.people.contains(where: { $0.id == candidate }) ? candidate : nil
    }

    /// The header name — a button into the person's profile when one resolves,
    /// plain text otherwise. A chevron fades in on hover as the only affordance.
    @ViewBuilder private var partnerNameLabel: some View {
        if let personID = navigablePersonID {
            Button {
                model.selectedPersonID = personID
                model.section = .people
            } label: {
                HStack(spacing: 4) {
                    Text(partnerName).font(DS.Typography.title).foregroundStyle(DS.Colors.ink)
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(DS.Colors.muted)
                        .opacity(hoveringName ? 1 : 0)
                }
            }
            .buttonStyle(.plain)
            .onHover { hoveringName = $0 }
            .help("View \(partnerName)'s profile")
        } else {
            Text(partnerName).font(DS.Typography.title)
        }
    }

    /// The deeper per-conversation read, laid out as a restrained wrapping
    /// strip — nothing renders when the thread has no opinion on any layer.
    @ViewBuilder private var intelStrip: some View {
        let merged = model.intel(forThread: threadID)
        let hasUrgency = merged.urgency != nil && merged.urgency != .none
        let hasAnything = hasUrgency || merged.action != nil || merged.openQuestion == true
            || !merged.commitments.isEmpty || merged.tone != nil || merged.temperature != nil
            || merged.effort == .thoughtful || model.suggestedFollowUpBy(forThread: threadID) != nil
        if hasAnything {
            FlowLayout(spacing: 6) {
                if hasUrgency { IntelChip(kind: .urgency(merged.urgency!, reason: merged.urgencyReason)) }
                if let action = merged.action { IntelChip(kind: .action(action)) }
                if merged.openQuestion == true {
                    Chip("They asked a question", systemImage: "questionmark.circle")
                }
                ForEach(merged.commitments, id: \.self) { c in
                    Chip("You promised: \(c)", systemImage: "checkmark.seal")
                }
                if let temp = merged.temperature {
                    Chip(temp.rawValue.capitalized, systemImage: temperatureSymbol(temp))
                } else if let tone = merged.tone {
                    Chip(tone.capitalized, systemImage: "face.smiling")
                }
                if merged.effort == .thoughtful {
                    Chip("Worth some thought", systemImage: "brain")
                }
                if let due = model.suggestedFollowUpBy(forThread: threadID) {
                    Button { model.armFollowup(thread: threadID, after: due.timeIntervalSinceNow) } label: {
                        Chip("Follow up by \(Self.weekdayFormatter.string(from: due))", systemImage: "bell")
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.bottom, DS.Space.s)
        }
    }

    private func temperatureSymbol(_ temp: IntelTemperature) -> String {
        switch temp {
        case .warm: return "flame"
        case .neutral: return "circle"
        case .cool: return "snowflake"
        }
    }

    static let weekdayFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEE"; return f
    }()

    /// Chips linking to related conversations (tap = jump), or nothing.
    @ViewBuilder private var relatedRow: some View {
        let related = model.relatedThreads(to: threadID)
        if !related.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: DS.Space.xs) {
                    Text("Related").font(DS.Typography.eyebrow).foregroundStyle(DS.Colors.muted)
                    ForEach(related) { other in
                        Button {
                            model.selectedThreadID = other.id
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: other.platform.symbolName)
                                    .font(.system(size: 8)).foregroundStyle(other.platform.tint)
                                Text(relatedTitle(other)).font(DS.Typography.eyebrow)
                                    .foregroundStyle(DS.Colors.ink).lineLimit(1)
                            }
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(DS.Colors.chip, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.bottom, DS.Space.s)
        }
    }

    private func relatedTitle(_ thread: OsmoThread) -> String {
        threadTitle(thread, members: (try? model.store.contacts(inThread: thread.id)) ?? [])
    }

    /// Deep link straight into the real conversation on its home platform, so
    /// nothing Osmo shows is ever a dead end. iMessage has no trustworthy URL
    /// scheme for a specific chat — it gets its own reveal path instead.
    private func platformChatURL() -> URL? {
        guard let thread else { return nil }
        let handle = members.first { !$0.isMe }?.handle
        return PlatformLinks.chatURL(platform: thread.platform, platformThreadID: thread.platformThreadID,
                                     providerThreadID: thread.providerThreadID,
                                     counterpartHandle: handle, isGroup: thread.isGroup)
    }

    private var canOpenInPlatform: Bool {
        guard let thread else { return false }
        if thread.platform == .imessage {
            return !(members.first { !$0.isMe }?.handle.isEmpty ?? true)
        }
        return platformChatURL() != nil
    }

    private func openInPlatform() {
        guard let thread else { return }
        if thread.platform == .imessage {
            revealIMessageConversation()
            return
        }
        if let url = platformChatURL() { NSWorkspace.shared.open(url) }
    }

    /// Best-effort: no public AppleScript API selects a specific chat by
    /// identifier, so this activates Messages (bringing it forward) and
    /// attempts the `imessage://` handle scheme alongside it — the honest
    /// combination, not a guaranteed jump to the exact conversation.
    private func revealIMessageConversation() {
        guard let handle = members.first(where: { !$0.isMe })?.handle, !handle.isEmpty else { return }
        try? IMessageSender().activateMessages()
        if let encoded = handle.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed),
           let url = URL(string: "imessage://\(encoded)") {
            NSWorkspace.shared.open(url)
        }
    }

    static let timeFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .none; f.timeStyle = .short; return f
    }()

    /// Messages grouped by calendar day, in order — drives the day separators.
    private var dayGroups: [(day: Date, messages: [OsmoMessage])] {
        let cal = Calendar.current
        var out: [(Date, [OsmoMessage])] = []
        for m in messages {
            let day = cal.startOfDay(for: m.sentAt)
            if let last = out.indices.last, out[last].0 == day { out[last].1.append(m) }
            else { out.append((day, [m])) }
        }
        return out.map { (day: $0.0, messages: $0.1) }
    }

    private func dayLabel(_ day: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(day) { return "Today" }
        if cal.isDateInYesterday(day) { return "Yesterday" }
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .none
        return f.string(from: day)
    }

    /// The display name of the person whose message `message` replies to.
    private func replyParentSender(_ message: OsmoMessage) -> String? {
        guard let parentID = message.inReplyToMessageID, let parent = messagesByID[parentID] else { return nil }
        if parent.isFromMe { return "You" }
        return parent.senderContactID.flatMap { contactsByID[$0]?.displayLabel }
    }

    private func react(_ message: OsmoMessage, type: String, emoji: String) {
        Task { await model.reactToIMessage(target: message, type: type, emoji: emoji) }
    }

    @ViewBuilder private var assist: some View {
        if let context = suggestionContext {
            SuggestionStrip(
                context: context, platform: thread?.platform ?? .imessage,
                sendTarget: sendTarget,
                onPick: { draft = $0 },
                onSent: { load(); showAssist = false })
                .padding(DS.Space.l)
                .background(DS.Colors.card)
        }
    }

    private var composeBar: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            // "Read before you send" — instant, local, reassurance-first.
            if let check = toneCheck {
                ToneCheckResult(check: check)
            }
            composeRow
        }
        .padding(DS.Space.m)
    }

    @State private var toneCheck: ToneCheck?

    private var composeRow: some View {
        HStack(alignment: .bottom, spacing: DS.Space.s) {
            Button { showAssist.toggle() } label: {
                Image(systemName: "sparkles").font(.system(size: 14, weight: .medium))
                    .foregroundStyle(showAssist ? .white : DS.Colors.accent)
                    .padding(DS.Space.s)
                    .background(showAssist ? DS.Colors.accent : DS.Colors.chip, in: Circle())
            }
            .buttonStyle(.plain)
            .help("Draft with Osmo")

            Button { runToneCheck() } label: {
                Image(systemName: "checkmark.seal").font(.system(size: 14, weight: .medium))
                    .foregroundStyle(DS.Colors.accent)
                    .padding(DS.Space.s)
                    .background(DS.Colors.chip, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            .help("Check how this lands before you send it")

            TextEditor(text: $draft)
                .font(DS.Typography.body)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 32, maxHeight: 120)
                .padding(.horizontal, DS.Space.s).padding(.vertical, DS.Space.xs)
                .background(DS.Colors.card, in: RoundedRectangle(cornerRadius: DS.Radius.l))
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.l).stroke(DS.Colors.hairline, lineWidth: 1))

            let canSend = model.connections.canDirectSend(thread?.platform ?? .imessage)
            PillButton(canSend ? "Send" : "Copy", icon: canSend ? "paperplane.fill" : "doc.on.doc") {
                sendOrCopy()
            }
            .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private func runToneCheck() {
        let turns = model.turns(forThread: threadID)
        toneCheck = ToneCheck.check(draft: draft,
                                    partner: PartnerProfile.read(turns),
                                    read: ThreadRead.read(turns))
    }

    // MARK: - Data

    private func load() {
        thread = try? model.store.thread(id: threadID)
        messages = (try? model.store.messages(inThread: threadID)) ?? []
        if model.demoMode {
            let cutoff = DemoScope.messageCutoff()
            messages = messages.filter { $0.sentAt >= cutoff }
        }
        members = (try? model.store.contacts(inThread: threadID)) ?? []
        contactsByID = Dictionary(members.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        reactionsByTarget = (try? model.store.reactions(inThread: threadID)) ?? [:]
        messagesByID = Dictionary(messages.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        attachmentsByMessage = (try? model.store.attachments(inThread: threadID)) ?? [:]
        if draft.isEmpty { draft = (try? model.store.draft(forThread: threadID)) ?? "" }
    }
    private func saveDraft() { try? model.store.saveDraft(draft, forThread: threadID) }

    private func snooze(hours: Int) {
        try? model.store.snooze(thread: threadID, until: Date().addingTimeInterval(Double(hours) * 3600))
        model.reload()
        model.selectedThreadID = nil
    }

    private var partnerName: String {
        guard let thread else { return "Conversation" }
        return threadTitle(thread, members: members)
    }
    private var sendTarget: String {
        ContextAssembler(store: model.store, projects: model.projects)
            .sendTarget(threadID: threadID, platform: thread?.platform ?? .imessage)
    }
    private var suggestionContext: SuggestionContext? {
        guard let platform = thread?.platform else { return nil }
        return ContextAssembler(store: model.store, projects: model.projects,
                                selfPreamble: model.onboardingProfile.promptPreamble)
            .context(threadID: threadID, platform: platform, personName: partnerName)
    }

    private func sendOrCopy() {
        let text = draft
        let platform = thread?.platform ?? .imessage
        Task {
            let ok = await model.send(text, platform: platform, target: sendTarget)
            await MainActor.run {
                if ok { draft = ""; try? model.store.saveDraft("", forThread: threadID); load() }
                else {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    model.toast = "Copied — paste it into \(platform.displayName)."
                }
            }
        }
    }
}

/// One message bubble with full iMessage fidelity: in a group, incoming bubbles
/// show the sender's name + avatar; a reply shows a quoted stub of its parent;
/// tapback reactions cluster on the bubble's outer corner; right-click (or the
/// hover menu) sends a reaction.
struct MessageBubble: View {
    let message: OsmoMessage
    var isGroup: Bool = false
    var senderName: String? = nil
    var senderAvatar: Data? = nil
    var reactions: [MessageReaction] = []
    var replyParent: OsmoMessage? = nil
    var replyParentSender: String? = nil
    var replyParentAttachments: [OsmoAttachment] = []
    /// Send time ("3:42 PM") shown under the bubble — real-platform fidelity.
    var timeText: String? = nil
    /// Media/files/shared-post attachments on this message. An attachment-only
    /// message (empty text) renders the grid with no empty text pill beneath it.
    var attachments: [OsmoAttachment] = []
    /// nil = no react affordance (own messages).
    var onReact: ((_ type: String, _ emoji: String) -> Void)? = nil

    private var showSender: Bool { isGroup && !message.isFromMe && senderName != nil }

    var body: some View {
        HStack(alignment: .bottom, spacing: DS.Space.xs) {
            if message.isFromMe { Spacer(minLength: 60) }
            else if isGroup {
                AvatarView(name: senderName ?? "?", data: senderAvatar, size: 24)
                    .opacity(showSender ? 1 : 0)   // keep alignment when unknown
            }
            VStack(alignment: message.isFromMe ? .trailing : .leading, spacing: 2) {
                if showSender, let senderName {
                    Text(senderName).font(DS.Typography.eyebrow)
                        .foregroundStyle(DS.Colors.muted).padding(.horizontal, DS.Space.s)
                }
                if let replyParent { replyStub(replyParent) }
                if !attachments.isEmpty { attachmentGrid }
                if !message.text.isEmpty {
                    bubble
                        .overlay(alignment: message.isFromMe ? .topLeading : .topTrailing) {
                            reactionCluster.offset(x: message.isFromMe ? -8 : 8, y: -12)
                        }
                } else if !attachments.isEmpty {
                    // Attachment-only: the reaction cluster still needs a perch.
                    Color.clear.frame(width: 1, height: 1)
                        .overlay(alignment: message.isFromMe ? .topLeading : .topTrailing) {
                            reactionCluster.offset(x: message.isFromMe ? -8 : 8, y: -12)
                        }
                }
                if let timeText {
                    Text(timeText).font(.system(size: 9))
                        .foregroundStyle(DS.Colors.muted.opacity(0.8))
                        .padding(.horizontal, DS.Space.xs)
                }
            }
            if !message.isFromMe { Spacer(minLength: 60) }
        }
    }

    private var bubble: some View {
        Text(message.text)
            .font(DS.Typography.body)
            .foregroundStyle(message.isFromMe ? .white : DS.Colors.ink)
            .padding(.horizontal, DS.Space.m).padding(.vertical, DS.Space.s)
            .background(message.isFromMe ? DS.Colors.accent : DS.Colors.card,
                        in: RoundedRectangle(cornerRadius: DS.Radius.l, style: .continuous))
            .overlay(message.isFromMe ? nil : RoundedRectangle(cornerRadius: DS.Radius.l, style: .continuous)
                .stroke(DS.Colors.hairlineSoft, lineWidth: 1))
            .textSelection(.enabled)
            .contextMenu {
                if let onReact {
                    ForEach(Tapback.choices, id: \.type) { choice in
                        Button { onReact(choice.type, choice.emoji) } label: { Text(choice.emoji + "  " + choice.type.capitalized) }
                    }
                }
            }
    }

    /// Up to 4 attachments in a stack, "+N" for the rest — never a wall of media.
    @ViewBuilder private var attachmentGrid: some View {
        let shown = Array(attachments.prefix(4))
        let overflow = attachments.count - shown.count
        VStack(alignment: message.isFromMe ? .trailing : .leading, spacing: 4) {
            ForEach(shown) { att in attachmentView(att) }
            if overflow > 0 {
                Text("+\(overflow) more").font(DS.Typography.caption).foregroundStyle(DS.Colors.muted)
            }
        }
    }

    @ViewBuilder private func attachmentView(_ attachment: OsmoAttachment) -> some View {
        switch attachment.kind {
        case .image:
            ImageAttachmentView(message: message, attachment: attachment)
        case .video:
            FileAttachmentChip(message: message, attachment: attachment, icon: "play.circle.fill")
        case .audio:
            FileAttachmentChip(message: message, attachment: attachment, icon: "waveform")
        case .file:
            FileAttachmentChip(message: message, attachment: attachment, icon: "doc.fill")
        case .link:
            LinkAttachmentRow(attachment: attachment)
        }
    }

    /// A quoted mini-preview of the replied-to message (iMessage reply style).
    private func replyStub(_ parent: OsmoMessage) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 1).fill(DS.Colors.hairline).frame(width: 2, height: 14)
            if let s = replyParentSender {
                Text(s).font(DS.Typography.eyebrow).foregroundStyle(DS.Colors.muted)
            }
            Text(previewLine(parent, attachments: replyParentAttachments)).font(DS.Typography.caption)
                .foregroundStyle(DS.Colors.muted).lineLimit(1)
        }
        .padding(.horizontal, DS.Space.s).padding(.vertical, 2)
        .frame(maxWidth: 220, alignment: .leading)
        .opacity(0.85)
    }

    /// Grouped tapbacks as small emoji+count chips, like iMessage.
    @ViewBuilder private var reactionCluster: some View {
        if !reactions.isEmpty {
            let grouped = Dictionary(grouping: reactions, by: \.emoji)
                .sorted { $0.value.count > $1.value.count }
            HStack(spacing: 2) {
                ForEach(grouped, id: \.key) { emoji, list in
                    HStack(spacing: 1) {
                        Text(emoji).font(.system(size: 10))
                        if list.count > 1 {
                            Text("\(list.count)").font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(DS.Colors.muted)
                        }
                    }
                    .padding(.horizontal, 4).padding(.vertical, 2)
                    .background(DS.Colors.card, in: Capsule())
                    .overlay(Capsule().stroke(DS.Colors.hairlineSoft, lineWidth: 0.5))
                }
            }
            .shadow(color: DS.Colors.shadow, radius: 2, y: 1)
        }
    }
}

/// The overthink-stopper's answer card: a green "send it" when clean, otherwise
/// the specific, kind flags. Shared by the inbox compose bar and the pill.
struct ToneCheckResult: View {
    let check: ToneCheck

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            HStack(spacing: DS.Space.xs) {
                Image(systemName: check.flags.isEmpty ? "checkmark.circle.fill" : "lightbulb")
                    .font(.system(size: 12))
                    .foregroundStyle(check.flags.isEmpty ? DS.Colors.green : DS.Colors.accent)
                Text(check.verdict).font(DS.Typography.captionEm).foregroundStyle(DS.Colors.ink)
            }
            ForEach(check.flags, id: \.title) { flag in
                VStack(alignment: .leading, spacing: 1) {
                    Text(flag.title).font(DS.Typography.captionEm).foregroundStyle(DS.Colors.ink)
                    Text(flag.detail).font(DS.Typography.caption).foregroundStyle(DS.Colors.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.leading, DS.Space.l)
            }
        }
        .padding(DS.Space.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background((check.flags.isEmpty ? DS.Colors.green : DS.Colors.accent).opacity(0.07),
                    in: RoundedRectangle(cornerRadius: DS.Radius.l, style: .continuous))
    }
}

/// A compact chip for the deeper Action/Time intel layers — an urgency read or
/// the single word for what's actually owed. Restrained by design: callers cap
/// how many render per row (see `ThreadRow.intelChips`).
struct IntelChip: View {
    enum Kind {
        case urgency(IntelUrgency, reason: String?)
        case action(IntelAction)
    }
    let kind: Kind

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: symbolName).font(.system(size: 8, weight: .semibold))
            Text(label).font(DS.Typography.eyebrow)
        }
        .padding(.horizontal, 6).padding(.vertical, 1)
        .foregroundStyle(color)
        .background(color.opacity(0.12), in: Capsule())
        .lineLimit(1)
    }

    private var symbolName: String {
        switch kind {
        case .urgency: return "exclamationmark.circle"
        case .action(let action):
            switch action {
            case .reply: return "arrowshape.turn.up.left"
            case .decide: return "arrow.triangle.branch"
            case .schedule: return "calendar"
            case .pay: return "dollarsign.circle"
            case .task: return "checkmark.circle"
            case .fyi: return "info.circle"
            }
        }
    }

    private var label: String {
        switch kind {
        case .urgency(let level, let reason):
            switch level {
            case .overdue: return reason ?? "Overdue"
            case .today: return reason ?? "Today"
            case .soon: return reason ?? "Soon"
            case .none: return "—"
            }
        case .action(let action): return action.rawValue.capitalized
        }
    }

    private var color: Color {
        switch kind {
        case .urgency(let level, _):
            switch level {
            case .overdue: return DS.Colors.red
            case .today: return DS.Colors.amber
            case .soon, .none: return DS.Colors.muted
            }
        case .action: return DS.Colors.accent
        }
    }
}

/// A Kinso-style colored topic label. Color is a stable hash of the topic text
/// (unicode-scalar sum — String.hashValue is randomized per launch).
struct TopicChip: View {
    let topic: String

    private static let palette: [Color] = [
        Color(hex: 0x0A84FF), Color(hex: 0x30B0C7), Color(hex: 0xAF52DE),
        Color(hex: 0xFF9500), Color(hex: 0xFF2D55), Color(hex: 0x34C759),
    ]

    /// Stable per-topic color (unicode-scalar sum) — shared with the filter
    /// panel's topic chips so the same label always reads the same color.
    static func color(for topic: String) -> Color {
        let sum = topic.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        return palette[sum % palette.count]
    }

    var body: some View {
        Text(topic)
            .font(DS.Typography.eyebrow)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .foregroundStyle(Self.color(for: topic))
            .background(Self.color(for: topic).opacity(0.12), in: Capsule())
            .lineLimit(1)
    }
}

/// An inline image attachment — lazily fetched (or read straight from an
/// already-local iMessage path), cached on first render, tap-to-reveal.
struct ImageAttachmentView: View {
    @EnvironmentObject var model: AppModel
    let message: OsmoMessage
    let attachment: OsmoAttachment
    @State private var image: NSImage?
    @State private var notDownloaded = false

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable().scaledToFit()
                    .frame(maxHeight: 220)
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.l, style: .continuous))
                    .onTapGesture {
                        if let url = model.cachedMediaURL(for: attachment) {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        }
                    }
            } else if notDownloaded {
                notDownloadedChip
            } else {
                RoundedRectangle(cornerRadius: DS.Radius.l, style: .continuous)
                    .fill(DS.Colors.chip)
                    .frame(width: 180, height: 140)
                    .overlay(ProgressView().controlSize(.small))
            }
        }
        .task(id: attachment.id) { await load() }
    }

    private var notDownloadedChip: some View {
        HStack(spacing: 4) {
            Image(systemName: "photo.badge.exclamationmark").font(.system(size: 12))
            Text("Photo not downloaded").font(DS.Typography.caption)
        }
        .foregroundStyle(DS.Colors.muted)
        .padding(.horizontal, DS.Space.s).padding(.vertical, DS.Space.xs)
        .background(DS.Colors.chip, in: RoundedRectangle(cornerRadius: DS.Radius.l, style: .continuous))
    }

    private func load() async {
        if let hit = tryLoadFromDisk() { image = hit; return }
        // An iMessage attachment already has a known local path — if it's not
        // on disk, iCloud has evicted it and there is no server to refetch it
        // from (unlike Gmail/Slack/Unipile, which always have a remote copy).
        guard attachment.localPath == nil else { notDownloaded = true; return }
        model.ensureMediaFetched(attachment, message: message)
        for _ in 0..<10 {
            try? await Task.sleep(for: .milliseconds(400))
            if let hit = tryLoadFromDisk() { image = hit; return }
        }
        notDownloaded = true
    }

    private func tryLoadFromDisk() -> NSImage? {
        guard let url = model.cachedMediaURL(for: attachment),
              let data = try? Data(contentsOf: url) else { return nil }
        return NSImage(data: data)
    }
}

/// A video/audio/file chip: icon + filename + size, tap to fetch (if needed)
/// and reveal in Finder.
struct FileAttachmentChip: View {
    @EnvironmentObject var model: AppModel
    let message: OsmoMessage
    let attachment: OsmoAttachment
    let icon: String
    @State private var opening = false

    var body: some View {
        Button { open() } label: {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 14)).foregroundStyle(DS.Colors.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text(attachment.filename ?? attachment.kind.rawValue.capitalized)
                        .font(DS.Typography.captionEm).foregroundStyle(DS.Colors.ink).lineLimit(1)
                    if let size = attachment.sizeBytes {
                        Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                            .font(.system(size: 10)).foregroundStyle(DS.Colors.muted)
                    }
                }
                Spacer(minLength: 0)
                if opening { ProgressView().controlSize(.mini) }
            }
            .padding(.horizontal, DS.Space.s).padding(.vertical, DS.Space.xs)
            .background(DS.Colors.chip, in: RoundedRectangle(cornerRadius: DS.Radius.l, style: .continuous))
        }
        .buttonStyle(.plain)
        .frame(maxWidth: 220, alignment: .leading)
    }

    private func open() {
        if let url = model.cachedMediaURL(for: attachment) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return
        }
        guard !opening, attachment.remoteRef != nil else { return }
        opening = true
        Task {
            model.ensureMediaFetched(attachment, message: message)
            for _ in 0..<15 {
                try? await Task.sleep(for: .milliseconds(400))
                if let url = model.cachedMediaURL(for: attachment) {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                    break
                }
            }
            opening = false
        }
    }
}

/// A shared post/reel row: title + destination URL, opens in the browser
/// (there are no bytes to fetch for a `link`-kind attachment).
struct LinkAttachmentRow: View {
    let attachment: OsmoAttachment

    var body: some View {
        Button {
            guard let s = attachment.linkURL, let url = URL(string: s) else { return }
            NSWorkspace.shared.open(url)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "link").font(.system(size: 12)).foregroundStyle(DS.Colors.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text(attachment.title ?? "Shared post").font(DS.Typography.captionEm)
                        .foregroundStyle(DS.Colors.ink).lineLimit(1)
                    if let s = attachment.linkURL {
                        Text(s).font(.system(size: 10)).foregroundStyle(DS.Colors.muted).lineLimit(1)
                    }
                }
            }
            .padding(.horizontal, DS.Space.s).padding(.vertical, DS.Space.xs)
            .background(DS.Colors.chip, in: RoundedRectangle(cornerRadius: DS.Radius.l, style: .continuous))
        }
        .buttonStyle(.plain)
        .frame(maxWidth: 240, alignment: .leading)
    }
}
