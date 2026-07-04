import SwiftUI
import OsmoCore
import OsmoBrain

/// Unified cross-platform inbox: a thread list + a detail with transcript,
/// compose bar, and the "Draft with Osmo" strip. A chip row filters the list
/// to one platform (only platforms that actually have threads are offered).
struct InboxView: View {
    @EnvironmentObject var model: AppModel
    @State private var platformFilter: Platform?

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
            if !presentPlatforms.isEmpty {
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
                                   title: "Nothing here",
                                   message: "No \(platformFilter?.displayName ?? "") conversations yet.")
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

    /// Platforms that actually have threads, in a stable order.
    private var presentPlatforms: [Platform] {
        let present = Set(model.threads.map(\.platform))
        return Platform.allCases.filter { present.contains($0) }
    }

    private var filteredThreads: [OsmoThread] {
        guard let platformFilter else { return model.threads }
        return model.threads.filter { $0.platform == platformFilter }
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DS.Space.s) {
                filterChip(label: "All", symbol: nil, tint: DS.Colors.ink, selected: platformFilter == nil) {
                    platformFilter = nil
                }
                ForEach(presentPlatforms, id: \.self) { platform in
                    filterChip(label: platform.displayName,
                               symbol: platform.symbolName,
                               tint: platform.tint,
                               selected: platformFilter == platform) {
                        platformFilter = platformFilter == platform ? nil : platform
                    }
                }
            }
            .padding(.horizontal, DS.Space.m)
            .padding(.vertical, DS.Space.s)
        }
    }

    private func filterChip(label: String, symbol: String?, tint: Color,
                            selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 9))
                        .foregroundStyle(selected ? .white : tint)
                }
                Text(label).font(DS.Typography.eyebrow)
            }
            .padding(.horizontal, DS.Space.s)
            .padding(.vertical, 4)
            .foregroundStyle(selected ? .white : DS.Colors.ink)
            .background(selected ? DS.Colors.ink : DS.Colors.chip, in: Capsule())
            .overlay(Capsule().stroke(DS.Colors.hairline, lineWidth: selected ? 0 : 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(label) conversations")
        .accessibilityAddTraits(selected ? .isSelected : [])
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

struct ThreadRow: View {
    @EnvironmentObject var model: AppModel
    let thread: OsmoThread

    var body: some View {
        HStack(spacing: DS.Space.m) {
            AvatarView(name: title, data: avatar, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: DS.Space.xs) {
                    Text(title).font(DS.Typography.bodyEm).foregroundStyle(DS.Colors.ink).lineLimit(1)
                    Image(systemName: thread.platform.symbolName)
                        .font(.system(size: 9)).foregroundStyle(thread.platform.tint)
                }
                Text(preview).font(DS.Typography.caption).foregroundStyle(DS.Colors.muted).lineLimit(1)
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }

    private var firstContact: OsmoContact? {
        (try? model.store.contacts(inThread: thread.id))?.first
    }
    private var title: String {
        if let t = thread.title, !t.isEmpty { return t }
        return firstContact?.displayLabel ?? "New conversation"
    }
    private var avatar: Data? { firstContact?.avatarData }
    private var preview: String {
        (try? model.store.lastMessage(inThread: thread.id))?.text ?? ""
    }
}

/// Transcript + compose + AI assist for one thread.
struct ThreadDetailView: View {
    @EnvironmentObject var model: AppModel
    let threadID: UUID

    @State private var messages: [OsmoMessage] = []
    @State private var draft: String = ""
    @State private var showAssist = false
    @State private var thread: OsmoThread?

    var body: some View {
        VStack(spacing: 0) {
            transcript
            Divider()
            if showAssist { assist }
            composeBar
        }
        .background(DS.Colors.paper)
        .onAppear { load(); model.focusedThreadID = threadID }
        .onDisappear { saveDraft(); if model.focusedThreadID == threadID { model.focusedThreadID = nil } }
    }

    private var transcript: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                HStack {
                    Text(partnerName).font(DS.Typography.title)
                    if let platform = thread?.platform {
                        Chip(platform.displayName, systemImage: platform.symbolName)
                    }
                    Spacer()
                    Menu {
                        Button("Snooze 3 hours") { snooze(hours: 3) }
                        Button("Snooze until tomorrow") { snooze(hours: 18) }
                    } label: { Image(systemName: "clock") }
                        .menuStyle(.borderlessButton).fixedSize()
                }
                .padding(.bottom, DS.Space.s)

                ForEach(messages) { message in MessageBubble(message: message) }
            }
            .padding(DS.Space.l)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
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
        HStack(alignment: .bottom, spacing: DS.Space.s) {
            Button { showAssist.toggle() } label: {
                Image(systemName: "sparkles").font(.system(size: 14, weight: .medium))
                    .foregroundStyle(showAssist ? .white : DS.Colors.accent)
                    .padding(DS.Space.s)
                    .background(showAssist ? DS.Colors.accent : DS.Colors.chip, in: Circle())
            }
            .buttonStyle(.plain)
            .help("Draft with Osmo")

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
        .padding(DS.Space.m)
    }

    // MARK: - Data

    private func load() {
        thread = try? model.store.thread(id: threadID)
        messages = (try? model.store.messages(inThread: threadID)) ?? []
        if draft.isEmpty { draft = (try? model.store.draft(forThread: threadID)) ?? "" }
    }
    private func saveDraft() { try? model.store.saveDraft(draft, forThread: threadID) }

    private func snooze(hours: Int) {
        try? model.store.snooze(thread: threadID, until: Date().addingTimeInterval(Double(hours) * 3600))
        model.reload()
        model.selectedThreadID = nil
    }

    private var partnerName: String {
        if let t = thread?.title, !t.isEmpty { return t }
        return (try? model.store.contacts(inThread: threadID))?.first?.displayLabel ?? "Conversation"
    }
    private var sendTarget: String {
        ContextAssembler(store: model.store, projects: model.projects)
            .sendTarget(threadID: threadID, platform: thread?.platform ?? .imessage)
    }
    private var suggestionContext: SuggestionContext? {
        guard let platform = thread?.platform else { return nil }
        return ContextAssembler(store: model.store, projects: model.projects)
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

struct MessageBubble: View {
    let message: OsmoMessage
    var body: some View {
        HStack {
            if message.isFromMe { Spacer(minLength: 60) }
            Text(message.text)
                .font(DS.Typography.body)
                .foregroundStyle(message.isFromMe ? .white : DS.Colors.ink)
                .padding(.horizontal, DS.Space.m).padding(.vertical, DS.Space.s)
                .background(message.isFromMe ? DS.Colors.accent : DS.Colors.card,
                            in: RoundedRectangle(cornerRadius: DS.Radius.l, style: .continuous))
                .overlay(message.isFromMe ? nil : RoundedRectangle(cornerRadius: DS.Radius.l, style: .continuous)
                    .stroke(DS.Colors.hairlineSoft, lineWidth: 1))
                .textSelection(.enabled)
            if !message.isFromMe { Spacer(minLength: 60) }
        }
    }
}
