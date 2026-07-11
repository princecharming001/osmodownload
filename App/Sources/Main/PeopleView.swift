import SwiftUI
import OsmoCore
import OsmoBrain

/// People: the identity-graph roster + a detail with cross-platform timeline,
/// editable memory, and merge review.
struct PeopleView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HSplitView {
            list.frame(minWidth: 240, maxWidth: 320)
            detail.frame(maxWidth: .infinity)
        }
    }

    private var list: some View {
        Group {
            if model.people.isEmpty {
                EmptyStateView(icon: "person.2", title: "No people yet",
                               message: "As conversations sync, Osmo builds a profile per person — recognized across platforms.",
                               cta: ("Connect", { model.section = .connections }))
            } else {
                List(selection: $model.selectedPersonID) {
                    // Dedupe by name-pair and cap: repeated re-imports can spawn
                    // dozens of identical group-title suggestions ("General &
                    // General"), which buried the actual people list.
                    let reviewable = dedupedSuggestions()
                    if !reviewable.isEmpty {
                        Section("Review") {
                            ForEach(Array(reviewable.prefix(5).enumerated()), id: \.offset) { _, suggestion in
                                MergeSuggestionRow(suggestion: suggestion)
                            }
                            if reviewable.count > 5 {
                                Text("\(reviewable.count - 5) more after these")
                                    .font(DS.Typography.caption).foregroundStyle(DS.Colors.muted)
                            }
                        }
                    }
                    Section("Everyone") {
                        ForEach(model.people) { person in
                            PersonRowView(person: person).tag(person.id)
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .background(DS.Colors.card)
    }

    /// One suggestion per distinct name pair — merging/rejecting that one
    /// resolves the whole family of duplicates on the next graph rebuild.
    private func dedupedSuggestions() -> [MergeSuggestion] {
        var seen = Set<String>()
        return model.mergeSuggestions.filter { s in
            let key = [s.displayNameA, s.displayNameB].sorted().joined(separator: "|").lowercased()
            return seen.insert(key).inserted
        }
    }

    @ViewBuilder private var detail: some View {
        if let id = model.selectedPersonID, let person = model.people.first(where: { $0.id == id }) {
            PersonDetailView(person: person).id(id)
        } else {
            EmptyStateView(icon: "person.crop.circle",
                           title: "Select someone",
                           message: "See every conversation with them and what Osmo remembers.")
        }
    }
}

struct PersonRowView: View {
    let person: PersonRow
    var body: some View {
        HStack(spacing: DS.Space.m) {
            AvatarView(name: person.name, data: person.avatar, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(person.name).font(DS.Typography.bodyEm).foregroundStyle(DS.Colors.ink).lineLimit(1)
                // Who they are (public profile), then where you talk.
                if let headline = person.headline {
                    Text(headline).font(DS.Typography.caption)
                        .foregroundStyle(DS.Colors.muted).lineLimit(1)
                }
                HStack(spacing: 3) {
                    ForEach(person.platforms, id: \.self) { p in
                        Image(systemName: p.symbolName).font(.system(size: 8)).foregroundStyle(p.tint)
                    }
                }
            }
            Spacer()
            StatusPill(status: person.status)
        }
        .padding(.vertical, 2)
    }
}

struct MergeSuggestionRow: View {
    @EnvironmentObject var model: AppModel
    let suggestion: MergeSuggestion

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            Text("\(suggestion.displayNameA) & \(suggestion.displayNameB) — same person?")
                .font(DS.Typography.captionEm).lineLimit(1)
            Text(suggestion.reason).font(DS.Typography.caption).foregroundStyle(DS.Colors.muted).lineLimit(2)
            HStack {
                PillButton("Merge") { merge() }
                Button("Not the same") { reject() }
                    .font(DS.Typography.captionEm).buttonStyle(.plain).foregroundStyle(DS.Colors.muted)
            }
        }
        .padding(.vertical, 2)
    }

    /// Resolve the person IDs behind the suggested contacts and merge them.
    private func merge() {
        let contactIDs = suggestion.contactIDsA + suggestion.contactIDsB
        let contacts = ((try? model.store.contacts()) ?? []).filter { contactIDs.contains($0.id) }
        let personIDs = Array(Set(contacts.compactMap { $0.personID }))
        // Fewer than two distinct people means the graph already links them —
        // treat as a no-op success (feedback beats a silent dead button).
        guard personIDs.count >= 2 else {
            model.toast = "Already merged — they're the same person."
            model.reload()
            return
        }
        do {
            _ = try model.store.mergePeople(personIDs)
            model.forceGraphRebuild = true   // reflect the merge in the suggestions
            model.reload()
            model.toast = "Merged \(suggestion.displayNameA) & \(suggestion.displayNameB)."
        } catch {
            model.toast = "Couldn't merge — please try again."
        }
    }

    /// Persist a "not the same person" decision so this pair never returns.
    private func reject() {
        try? model.store.rejectMergePair(
            contactIDsA: suggestion.contactIDsA, contactIDsB: suggestion.contactIDsB)
        model.forceGraphRebuild = true       // drop the rejected pair from the list
        model.reload()
        model.toast = "Kept them separate."   // confirm the action (merge toasts too)
    }
}

struct StatusPill: View {
    let status: TextingStatus
    var body: some View {
        Text(label)
            .font(DS.Typography.eyebrow)
            .padding(.horizontal, DS.Space.s).padding(.vertical, 2)
            .foregroundStyle(hot ? .white : DS.Colors.muted)
            .background(hot ? DS.Colors.accent : DS.Colors.chip, in: Capsule())
    }
    private var hot: Bool { status == .needsReply || status == .leftOnRead }
    private var label: String {
        switch status {
        case .needsReply: return "Reply"
        case .leftOnRead: return "On read"
        case .waiting: return "Waiting"
        case .ghosted: return "Gone quiet"
        case .quiet: return "Quiet"
        case .sayHi: return "Say hi"
        }
    }
}

/// Person detail — the playbook for one relationship, in pitch order:
/// who they are → the read on them (how to talk to them + why) → your goal →
/// what Osmo remembers → every conversation across platforms.
struct PersonDetailView: View {
    @EnvironmentObject var model: AppModel
    let person: PersonRow

    @State private var note: String = ""
    @State private var goalText: String = ""
    @State private var profile: PartnerProfile?
    @State private var verdict: ReachOutVerdict?
    @State private var trajectory: Trajectory?
    /// The attachment-flavored read (space vs reassurance) + Gottman bid pattern —
    /// the psychology layer made visible on the person, not just fed to the brain.
    @State private var style: RelationalStyle?
    @State private var bids: BidRead?
    /// The person's threads + last-message snippets, resolved once per load (not
    /// re-queried from the store on every redraw of the detail).
    @State private var personThreads: [OsmoThread] = []
    @State private var timelineSnippets: [UUID: String] = [:]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.xl) {
                header
                profileCard
                dossierCard
                readCard
                goalCard
                memoryEditor
                timeline
            }
            .padding(DS.Space.xl)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .onAppear {
            note = (try? model.store.memory(forPerson: person.id))?.note ?? ""
            goalText = existingProject?.goalText ?? ""
            loadTimeline()
            let turns = combinedTurns()
            let now = Date()
            let read = PartnerProfile.read(turns)
            profile = read
            verdict = ReachOutVerdict.decide(read: ThreadRead.read(turns, now: now),
                                             partner: read, now: now)
            trajectory = Trajectory.read(turns, now: now)
            style = RelationalStyle.read(turns, now: now)
            bids = BidDetector.read(turns, now: now)
            model.ensureEnrichment(forPerson: person.id, name: person.name)
            model.ensureDossier(forPerson: person.id, name: person.name)
        }
        .onChange(of: model.dataVersion) { _, _ in loadTimeline() }
    }

    // MARK: Public profile — who they are before how you talk

    @ViewBuilder private var profileCard: some View {
        let enrichment = model.enrichmentByPerson[person.id]
        if !model.enrichmentEnabled {
            Text("Profile enrichment is off — turn it on in Settings → Privacy.")
                .font(DS.Typography.caption).foregroundStyle(DS.Colors.muted)
        } else if let e = enrichment {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                HStack(spacing: DS.Space.s) {
                    Eyebrow("Profile")
                    Text(sourceLabel(e.source))
                        .font(DS.Typography.eyebrow)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .foregroundStyle(DS.Colors.accent)
                        .background(DS.Colors.accent.opacity(0.10), in: Capsule())
                    Spacer()
                    Text(RelativeDateTimeFormatter().localizedString(for: e.fetchedAt, relativeTo: Date()))
                        .font(DS.Typography.eyebrow).foregroundStyle(DS.Colors.muted)
                    Button {
                        model.ensureEnrichment(forPerson: person.id, name: person.name, force: true)
                    } label: {
                        Image(systemName: "arrow.clockwise").font(.system(size: 10))
                            .frame(width: 22, height: 22).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).foregroundStyle(DS.Colors.muted)
                    .help("Refresh from LinkedIn + the web")
                    .accessibilityLabel("Refresh profile")
                }
                Card {
                    VStack(alignment: .leading, spacing: DS.Space.m) {
                        if let h = e.headline, !h.isEmpty {
                            Text(h).font(DS.Typography.bodyEm).foregroundStyle(DS.Colors.ink)
                        }
                        let role = [e.title, e.company, e.location].compactMap { $0 }.filter { !$0.isEmpty }
                        if !role.isEmpty {
                            Text(role.joined(separator: " · "))
                                .font(DS.Typography.caption).foregroundStyle(DS.Colors.muted)
                        }
                        if let s = e.summary, !s.isEmpty {
                            Text(s).font(DS.Typography.body).foregroundStyle(DS.Colors.ink)
                                .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                        }
                        if !e.positions.isEmpty {
                            VStack(alignment: .leading, spacing: 3) {
                                Eyebrow("Experience")
                                ForEach(e.positions.prefix(3), id: \.title) { p in
                                    Text("\(p.title) — \(p.company)\(p.period.map { " (\($0))" } ?? "")")
                                        .font(DS.Typography.caption).foregroundStyle(DS.Colors.ink)
                                }
                            }
                        }
                        if !e.education.isEmpty {
                            VStack(alignment: .leading, spacing: 3) {
                                Eyebrow("Education")
                                ForEach(e.education.prefix(2), id: \.school) { ed in
                                    Text(ed.school + (ed.degree.map { " — \($0)" } ?? ""))
                                        .font(DS.Typography.caption).foregroundStyle(DS.Colors.ink)
                                }
                            }
                        }
                        if !e.webFacts.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                Eyebrow("From the web")
                                ForEach(e.webFacts.prefix(4), id: \.text) { fact in
                                    HStack(alignment: .top, spacing: DS.Space.xs) {
                                        Circle().fill(DS.Colors.accent.opacity(0.5))
                                            .frame(width: 4, height: 4).padding(.top, 6)
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(fact.text).font(DS.Typography.caption)
                                                .foregroundStyle(DS.Colors.ink)
                                                .fixedSize(horizontal: false, vertical: true)
                                            if let url = URL(string: fact.url), let host = url.host() {
                                                Link(host.replacingOccurrences(of: "www.", with: ""),
                                                     destination: url)
                                                    .font(DS.Typography.eyebrow)
                                                    .foregroundStyle(DS.Colors.accent)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        if let urlString = e.linkedinURL, let url = URL(string: urlString) {
                            Link(destination: url) {
                                HStack(spacing: 4) {
                                    Text("Open LinkedIn").font(DS.Typography.captionEm)
                                    Image(systemName: "arrow.up.forward").font(.system(size: 8, weight: .semibold))
                                }
                            }
                            .foregroundStyle(DS.Colors.accent)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        // No row yet + fetch may be in flight or found nothing: stay quiet —
        // the dossier below already covers the relationship story.
    }

    private func sourceLabel(_ source: EnrichmentSource) -> String {
        switch source {
        case .linkedin: return "LinkedIn"
        case .web: return "Web"
        case .both: return "LinkedIn + Web"
        case .mock: return "Demo data"
        }
    }

    // MARK: The dossier — "remember every detail" before you next talk

    private var dossierCard: some View {
        let result = model.dossierByPerson[person.id]
            ?? Dossier.fallback(model.dossierContext(forPerson: person.id, name: person.name))
        return VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack {
                Eyebrow("Dossier")
                if model.dossierByPerson[person.id] != nil {
                    Image(systemName: "sparkle").font(.system(size: 8)).foregroundStyle(DS.Colors.accent)
                }
                Spacer()
            }
            Card {
                VStack(alignment: .leading, spacing: DS.Space.m) {
                    if !result.about.isEmpty {
                        Text(result.about).font(DS.Typography.body).foregroundStyle(DS.Colors.ink)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !result.remember.isEmpty {
                        VStack(alignment: .leading, spacing: 3) {
                            Eyebrow("Worth remembering", accent: true)
                            ForEach(result.remember, id: \.self) { line in
                                HStack(alignment: .top, spacing: DS.Space.xs) {
                                    Circle().fill(DS.Colors.accent.opacity(0.5))
                                        .frame(width: 4, height: 4).padding(.top, 6)
                                    Text(line).font(DS.Typography.body).foregroundStyle(DS.Colors.ink)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                    if result.about.isEmpty && result.remember.isEmpty {
                        Text("Not enough history yet — the dossier fills in as you talk.")
                            .font(DS.Typography.caption).foregroundStyle(DS.Colors.muted)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: The Read — the pitch's "it reads people" made visible

    /// A one-line Gottman turn-toward read — only when there's a real signal (a
    /// low turn-toward pattern with enough samples, or an unanswered last reach).
    private var bidInsight: String? {
        guard let bids else { return nil }
        if let rate = bids.turnTowardRate, rate < 0.5 {
            return "You've been turning toward about \(Int(rate * 100))% of their bids lately — worth leaning in."
        }
        if bids.lastBidMissed {
            return "Their last message was a reach for connection that hasn't been met yet."
        }
        return nil
    }

    /// Verdict detail + trajectory driver folded into one supporting line (so the
    /// card isn't a stack of same-weight grey sentences).
    private var verdictContext: String? {
        var parts: [String] = []
        if let d = verdict?.detail, !d.isEmpty { parts.append(sentence(d)) }
        if let dr = trajectory?.driver, !dr.isEmpty { parts.append(sentence(dr)) }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// Capitalize + end-punctuate a fragment so reads render as clean sentences.
    private func sentence(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard let f = t.first else { return t }
        let body = String(f).uppercased() + t.dropFirst()
        return "!?.".contains(body.last!) ? body : body + "."
    }

    @ViewBuilder private var readCard: some View {
        if let profile, !profile.isEmpty {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                Eyebrow("The read")
                Card {
                    VStack(alignment: .leading, spacing: DS.Space.m) {
                        // TIER 1 — the two calls that matter: reach out or not, and
                        // which way the relationship is moving.
                        HStack(spacing: DS.Space.s) {
                            if let verdict {
                                Label(verdict.headline, systemImage: verdict.kind == .goodTime ? "hand.wave" : verdict.kind == .yourTurn ? "arrowshape.turn.up.left" : "hourglass")
                                    .font(DS.Typography.captionEm)
                                    .padding(.horizontal, DS.Space.s).padding(.vertical, 3)
                                    .foregroundStyle(verdict.kind == .goodTime || verdict.kind == .yourTurn ? .white : DS.Colors.ink)
                                    .background(verdict.kind == .goodTime || verdict.kind == .yourTurn ? DS.Colors.accent : DS.Colors.chip, in: Capsule())
                            }
                            if let trajectory, trajectory.kind != .insufficient {
                                Label(trajectory.kind.rawValue.capitalized,
                                      systemImage: trajectory.kind == .warming ? "arrow.up.right" : trajectory.kind == .cooling ? "arrow.down.right" : "arrow.right")
                                    .font(DS.Typography.captionEm)
                                    .padding(.horizontal, DS.Space.s).padding(.vertical, 3)
                                    .foregroundStyle(trajectory.kind == .cooling ? DS.Colors.red : DS.Colors.ink)
                                    .background(DS.Colors.chip, in: Capsule())
                            }
                        }
                        if let ctx = verdictContext {
                            Text(ctx).font(DS.Typography.caption).foregroundStyle(DS.Colors.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        // TIER 2 — the dynamic read: how you two relate (space vs
                        // reassurance) + whether their bids are being met. The
                        // differentiator, so it gets an editorial pull-quote
                        // treatment (accent rule + italic), not another grey line.
                        if style?.note != nil || bidInsight != nil {
                            HairlineDivider()
                            HStack(alignment: .top, spacing: DS.Space.m) {
                                Rectangle().fill(DS.Colors.accent.opacity(0.4)).frame(width: 2)
                                VStack(alignment: .leading, spacing: DS.Space.xs) {
                                    Eyebrow("How you two relate", accent: true)
                                    if let note = style?.note {
                                        Text(sentence(note)).font(DS.Typography.body).italic()
                                            .foregroundStyle(DS.Colors.ink)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                    if let bidLine = bidInsight {
                                        Text(bidLine).font(DS.Typography.caption).foregroundStyle(DS.Colors.muted)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                            }
                        }

                        // TIER 3 — how they communicate + the directive.
                        FlowChips(items: profile.chips)
                        if let tonality = profile.tonality {
                            VStack(alignment: .leading, spacing: DS.Space.xs) {
                                Eyebrow("Tonality to strike", accent: true)
                                Text(tonality).font(DS.Typography.bodyEm).foregroundStyle(DS.Colors.ink)
                                if let why = profile.why {
                                    Text(why).font(DS.Typography.caption).foregroundStyle(DS.Colors.muted)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }

                        // Footnote — reply rhythm.
                        if let m = profile.medianReplySeconds {
                            HStack(spacing: DS.Space.xs) {
                                Image(systemName: "clock").font(.system(size: 10)).foregroundStyle(DS.Colors.muted)
                                Text("Typically replies in \(PartnerProfile.humanGap(m))\(profile.activeBlock.map { " · most active \($0)" } ?? "")")
                                    .font(DS.Typography.eyebrow).foregroundStyle(DS.Colors.muted)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                // The Read is a Pro surface — free users see it exists, blurred.
                .blur(radius: model.isPro ? 0 : 5)
                .overlay {
                    if !model.isPro {
                        VStack(spacing: DS.Space.s) {
                            Text("Osmo has a read on \(person.name.split(separator: " ").first.map(String.init) ?? person.name).")
                                .font(DS.Typography.bodyEm).foregroundStyle(DS.Colors.ink)
                            PillButton("Unlock with Pro", icon: "sparkles") { model.present(.paywall) }
                        }
                    }
                }
            }
        }
    }

    // MARK: Goal — "a goal for every relationship"

    private var goalCard: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            Eyebrow("Your goal with them")
            HStack(spacing: DS.Space.s) {
                Image(systemName: "target").font(.system(size: 12)).foregroundStyle(DS.Colors.accent)
                TextField("Land the client, repair the friendship, get the yes…", text: $goalText)
                    .textFieldStyle(.plain).font(DS.Typography.body)
                    .onSubmit { saveGoal() }
            }
            .padding(.horizontal, DS.Space.m).padding(.vertical, DS.Space.s)
            .background(DS.Colors.card, in: Capsule())
            .overlay(Capsule().stroke(DS.Colors.hairline, lineWidth: 1))
            if !goalText.isEmpty {
                Text("Every draft for them bends toward this — never at the cost of the relationship.")
                    .font(DS.Typography.caption).foregroundStyle(DS.Colors.muted)
            }
        }
    }

    private var existingProject: Project? {
        ((try? model.store.projects(forPerson: person.id)) ?? []).first { $0.status == .active }
    }

    private func saveGoal() {
        let text = goalText.trimmingCharacters(in: .whitespaces)
        if var project = existingProject {
            project.goalText = text
            if text.isEmpty { project.status = .archived }
            try? model.store.put(project)
        } else if !text.isEmpty {
            try? model.store.put(Project(personID: person.id, title: person.name, goalText: text))
        }
        model.reload()
        if !text.isEmpty { model.toast = "Goal set. Osmo will keep drafts pointed at it." }
    }

    /// Recent turns across this person's threads, chronological — the profile
    /// sample. Bounded so the page stays instant.
    private func combinedTurns() -> [ThreadTurn] {
        personThreads.prefix(4).flatMap { thread in
            let senderNames = groupSenderNames(store: model.store, threadID: thread.id)
            return ((try? model.store.recentMessages(inThread: thread.id, limit: 80)) ?? [])
                .reversed()
                .map { ThreadTurn(fromMe: $0.isFromMe, text: $0.text, sentAt: $0.sentAt,
                                  senderName: $0.isFromMe ? nil : $0.senderContactID.flatMap { senderNames?[$0] }) }
        }
    }

    private var header: some View {
        HStack(spacing: DS.Space.m) {
            AvatarView(name: person.name, data: person.avatar, size: 56)
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                Text(person.name).font(DS.Typography.display).foregroundStyle(DS.Colors.ink)
                HStack(spacing: DS.Space.xs) {
                    ForEach(person.platforms, id: \.self) { p in
                        Chip(p.displayName, systemImage: p.symbolName)
                    }
                }
            }
            Spacer()
        }
    }

    private var memoryEditor: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            Eyebrow("What Osmo remembers")
            TextEditor(text: $note)
                .font(DS.Typography.body).scrollContentBackground(.hidden)
                .frame(minHeight: 80)
                .padding(DS.Space.s)
                .background(DS.Colors.card, in: RoundedRectangle(cornerRadius: DS.Radius.l))
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.l).stroke(DS.Colors.hairlineSoft, lineWidth: 1))
                .onChange(of: note) { _, newValue in saveNote(newValue) }
        }
    }

    private var timeline: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            Eyebrow("Across every platform")
            if personThreads.isEmpty {
                Text("No conversations synced yet.")
                    .font(DS.Typography.caption).foregroundStyle(DS.Colors.muted)
            } else {
                // Grouped hairline rows in one container — the same list idiom as
                // Today, not a stack of heavy per-thread cards.
                VStack(spacing: 0) {
                    ForEach(Array(personThreads.enumerated()), id: \.element.id) { idx, thread in
                        Button {
                            model.selectedThreadID = thread.id
                            model.section = .inbox
                        } label: {
                            HStack(spacing: DS.Space.m) {
                                Image(systemName: thread.platform.symbolName)
                                    .font(.system(size: 12)).foregroundStyle(thread.platform.tint)
                                    .frame(width: 18)
                                Text(timelineSnippets[thread.id] ?? "")
                                    .font(DS.Typography.body).foregroundStyle(DS.Colors.ink).lineLimit(1)
                                Spacer(minLength: DS.Space.s)
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 10)).foregroundStyle(DS.Colors.muted)
                            }
                            .padding(.vertical, DS.Space.m).padding(.horizontal, DS.Space.l)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if idx < personThreads.count - 1 { HairlineDivider() }
                    }
                }
                .background(DS.Colors.card.opacity(0.5),
                            in: RoundedRectangle(cornerRadius: DS.Radius.xl, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.xl, style: .continuous)
                    .stroke(DS.Colors.hairline, lineWidth: 1))
            }
        }
    }

    /// Resolve this person's threads + last-message snippets once (onAppear and on
    /// dataVersion), so the timeline never hits the store during a plain redraw.
    private func loadTimeline() {
        let contacts = (try? model.store.contacts(forPerson: person.id)) ?? []
        let contactIDs = Set(contacts.map(\.id))
        let ts = model.threads.filter { thread in
            let threadContacts = (try? model.store.contacts(inThread: thread.id)) ?? []
            return threadContacts.contains { contactIDs.contains($0.id) }
        }
        personThreads = ts
        timelineSnippets = Dictionary(uniqueKeysWithValues: ts.map {
            ($0.id, (try? model.store.lastMessage(inThread: $0.id))?.text ?? "")
        })
    }

    private func saveNote(_ text: String) {
        var memory = (try? model.store.memory(forPerson: person.id))
            ?? RelationshipMemory(personID: person.id)
        memory.note = text
        memory.updatedAt = Date()
        try? model.store.put(memory)
    }
}

/// A small wrapping row of trait chips (the person-read surface).
struct FlowChips: View {
    let items: [String]
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 118), spacing: DS.Space.xs)],
                  alignment: .leading, spacing: DS.Space.xs) {
            ForEach(items, id: \.self) { item in
                Text(item)
                    .font(DS.Typography.captionEm)
                    .padding(.horizontal, DS.Space.s).padding(.vertical, 3)
                    .background(DS.Colors.chip, in: Capsule())
                    .foregroundStyle(DS.Colors.ink)
                    .lineLimit(1)
            }
        }
    }
}
