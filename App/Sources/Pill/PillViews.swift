import SwiftUI
import OsmoCore
import OsmoBrain
import OsmoShell

/// The pill's root — anchors content to bottom-center of the oversized panel and
/// morphs between the collapsed pill and the expanded panel. Reports the
/// interactive shape so clicks outside pass through.
struct PillRootView: View {
    @ObservedObject var controller: PillController
    @EnvironmentObject var model: AppModel
    @Namespace private var morph

    var body: some View {
        VStack {
            Spacer(minLength: 0)
            content
                .background(shapeReporter)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 8)
    }

    @ViewBuilder private var content: some View {
        switch controller.state {
        case .hidden:
            EmptyView()
        case .idle:
            CollapsedPill(kind: .idle, matched: nil, controller: controller)
                .matchedGeometryEffect(id: "pill", in: morph)
        case .ready(let ctx):
            CollapsedPill(kind: .ready, matched: ctx.partnerName, controller: controller)
                .matchedGeometryEffect(id: "pill", in: morph)
        case .expanded(let ctx), .generating(let ctx):
            ExpandedPanel(context: ctx, generating: controller.state.isGenerating)
                .matchedGeometryEffect(id: "pill", in: morph)
                // Grows out of / shrinks back into the orb with depth, on top of
                // the geometry morph — the "pops open" feel.
                .transition(.asymmetric(
                    insertion: .scale(scale: 0.80, anchor: .bottom).combined(with: .opacity),
                    removal: .scale(scale: 0.90, anchor: .bottom).combined(with: .opacity)))
                .environmentObject(model)
        }
    }

    /// Reports the current content bounds (in window coords) as the interactive
    /// rect so the hit-test view lets clicks outside pass through.
    private var shapeReporter: some View {
        GeometryReader { geo in
            Color.clear.onChange(of: geo.frame(in: .global), initial: true) { _, frame in
                // SwiftUI global == window coords here (panel fills the window).
                controller.interactiveRects = [frame]
            }
        }
    }
}

private extension PillState {
    var isGenerating: Bool { if case .generating = self { return true }; return false }
}

/// The small always-present pill — a bare liquid-glass orb. No logo, no text:
/// state reads only through the glass, a soft accent bloom, and a gentle pulse
/// when a conversation is detected. Tap to expand; drag to reposition.
struct CollapsedPill: View {
    enum Kind { case idle, ready }
    let kind: Kind
    let matched: String?
    let controller: PillController

    @State private var dragging = false
    @State private var pulse = false
    @State private var lastX: CGFloat = 0
    @State private var lastY: CGFloat = 0

    private let diameter: CGFloat = 28
    private var ready: Bool { kind == .ready }

    var body: some View {
        Circle()
            .fill(.clear)
            .frame(width: diameter, height: diameter)
            // Ready = a soft accent bloom behind the glass; idle = none.
            .background(
                Circle().fill(DS.Colors.accent)
                    .blur(radius: 8)
                    .opacity(ready ? (pulse ? 0.34 : 0.20) : 0)
                    .frame(width: diameter + 8, height: diameter + 8)
            )
            .background(GlassSurface(shape: Circle()))
            .clipShape(Circle())
            .overlay(
                Circle().stroke(ready ? DS.Colors.accent.opacity(0.55) : DS.Colors.glassBorder,
                                lineWidth: 1)
            )
            // A tiny inner glass dot gives the orb a lens-like center without text.
            .overlay(
                Circle().fill(.white.opacity(0.28))
                    .frame(width: 5, height: 5)
                    .offset(x: -diameter * 0.18, y: -diameter * 0.18)
                    .blur(radius: 0.5)
            )
            .shadow(color: DS.Colors.shadow, radius: 10, x: 0, y: 3)
            .scaleEffect(ready && pulse ? 1.06 : 1.0)
            .contentShape(Circle())
            .onTapGesture { if !dragging { controller.tapPill() } }
            .gesture(
                DragGesture(minimumDistance: 4)
                    .onChanged { value in
                        dragging = true
                        controller.dragBy(CGSize(width: value.translation.width - lastX,
                                                 height: value.translation.height - lastY))
                        lastX = value.translation.width; lastY = value.translation.height
                    }
                    .onEnded { _ in dragging = false; lastX = 0; lastY = 0 }
            )
            .onChange(of: ready) { _, isReady in animatePulse(isReady) }
            .onAppear { animatePulse(ready) }
            .accessibilityLabel(matched.map { "Osmo — draft a reply to \($0)" } ?? "Osmo")
            .accessibilityAddTraits(.isButton)
    }

    private func animatePulse(_ on: Bool) {
        pulse = false
        guard on else { return }
        withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) { pulse = true }
    }
}

/// A broad tone frame, chosen BEFORE generation (unlike SuggestionStrip's own
/// after-the-fact "regenerate warmer" menu). `hint` feeds `toneOverride`;
/// `.balanced` sends nil — Osmo's own judgment, no steer.
enum ToneOption: String, CaseIterable, Identifiable {
    case balanced = "Balanced", warm = "Warm", professional = "Professional",
         direct = "Direct", playful = "Playful", firm = "Firm", apologetic = "Apologetic"
    var id: String { rawValue }
    var hint: String? {
        switch self {
        case .balanced: return nil
        case .warm: return "warmer and more personal"
        case .professional: return "more professional and polished"
        case .direct: return "more direct and to the point"
        case .playful: return "playful and light"
        case .firm: return "firm and clear about the boundary"
        case .apologetic: return "genuinely apologetic"
        }
    }
}

/// The expanded panel: WHO you're talking to (cross-platform search to
/// confirm/correct), a tone frame + custom intent, a draft box, and a
/// mode-switching primary — "Draft for me" when empty, "Analyze" once you've
/// written something — plus the always-free deterministic tone Check.
struct ExpandedPanel: View {
    @EnvironmentObject var model: AppModel
    let context: PillContext
    let generating: Bool

    @State private var intent: String = ""
    // Bumped only when the user SUBMITS the intent — so the strip re-drafts once
    // per intent, not once per keystroke.
    @State private var submittedIntent: String = ""
    @State private var selectedTone: ToneOption = .balanced
    @State private var draftVersion = 0
    // Resolved once (store queries are synchronous) instead of on every render.
    @State private var resolved: (context: SuggestionContext, target: String)?
    // The editable message the user will send.
    @State private var draft: String = ""
    // "Read before you send" result (cleared whenever the draft changes).
    @State private var toneCheck: ToneCheck?
    // The three-takes strip mounts only once the user explicitly asks for it —
    // never burns a metered draft just because the panel opened.
    @State private var showSuggestions = false
    @State private var analysis: MessageJudge.Result?
    @State private var analyzing = false
    // WHO — Osmo's inference, correctable via cross-platform search.
    @State private var overridePerson: Person?
    @State private var overridePlatform: Platform?
    @State private var hitPlatforms: [Platform] = []
    @State private var pickerOpen = false
    @State private var query = ""

    private var platform: Platform { overridePlatform ?? context.platform ?? .imessage }
    private var partnerName: String {
        overridePerson?.displayName ?? context.partnerName ?? "Someone"
    }

    var body: some View {
        GlassCard(cornerRadius: DS.Radius.xxl) {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                header
                platformChooser
                readStrip
                if pickerOpen {
                    // Focused on WHO — show just the picker; everything else
                    // returns once a person is confirmed (keeps the panel tidy).
                    personPicker
                } else {
                    toneRow
                    if showSuggestions, let resolved {
                        SuggestionStrip(
                            context: resolved.context,
                            platform: platform,
                            sendTarget: resolved.target,
                            onPick: { text in draft = text; showSuggestions = false },
                            onSent: { PillController.shared.escape() })
                            .environmentObject(model)
                            .id(draftVersion)   // re-draft only when the version bumps
                    }
                    draftBox
                    if let analysis {
                        AnalysisView(result: analysis, onUse: { draft = $0 }, onClear: { self.analysis = nil })
                    }
                    intentField
                    // The conversion moment, stated plainly — never a surprise cutoff.
                    if let remaining = model.draftsRemaining {
                        HStack(spacing: DS.Space.xs) {
                            Text("\(remaining) free draft\(remaining == 1 ? "" : "s") left this week")
                                .font(DS.Typography.eyebrow).foregroundStyle(DS.Colors.muted)
                            Spacer()
                            Button("Go unlimited") { model.activeSheet = .paywall }
                                .buttonStyle(.plain).font(DS.Typography.eyebrow)
                                .foregroundStyle(DS.Colors.accent)
                        }
                    }
                }
            }
            .padding(DS.Space.l)
            .frame(width: 460)
        }
        .onExitCommand { PillController.shared.escape() }
        .onAppear { resolve() }
        // Refreshes the read strip/transcript mid-compose (a reply lands while
        // you're drafting) — pure local reads, never re-runs a paid call.
        .onChange(of: model.dataVersion) { _, _ in resolve() }
    }

    // MARK: Header + person picker

    /// One line of visible intelligence: the read on this person (tonality +
    /// tempo), computed from the same history the drafts are grounded in. This
    /// is what separates Osmo from a generic writing tool at the moment of use.
    @ViewBuilder private var readStrip: some View {
        if let resolved {
            let read = PartnerProfile.read(resolved.context.transcript)
            if let tonality = read.tonality {
                HStack(spacing: DS.Space.xs) {
                    Image(systemName: "eye").font(.system(size: 9)).foregroundStyle(DS.Colors.accent)
                    Text("The read: \(tonality)\(read.medianReplySeconds.map { " Replies in ~\(PartnerProfile.humanGap($0))." } ?? "")")
                        .font(DS.Typography.caption).foregroundStyle(DS.Colors.muted)
                        .lineLimit(2)
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: DS.Space.s) {
            Image(systemName: platform.symbolName).font(.system(size: 12))
                .foregroundStyle(platform.tint)
            // Tappable "who" chip — confirm or correct the inferred person.
            Button {
                withAnimation(DS.Motion.standard) { pickerOpen.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Text(partnerName).font(DS.Typography.title).foregroundStyle(DS.Colors.ink)
                        .lineLimit(1)
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(DS.Colors.muted)
                        .rotationEffect(.degrees(pickerOpen ? 180 : 0))
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Change who you're messaging — currently \(partnerName)")
            Spacer()
            Button { PillController.shared.escape() } label: {
                Image(systemName: "xmark").font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.plain).foregroundStyle(DS.Colors.muted)
            .accessibilityLabel("Close")
        }
    }

    /// When the chosen person has more than one platform, small chips pick
    /// which of their threads to ground the draft on.
    @ViewBuilder private var platformChooser: some View {
        if hitPlatforms.count > 1 {
            HStack(spacing: 4) {
                ForEach(hitPlatforms, id: \.self) { p in
                    let selected = p == overridePlatform
                    Button {
                        overridePlatform = p
                        resolve(); draftVersion += 1
                    } label: {
                        Image(systemName: p.symbolName).font(.system(size: 9))
                            .padding(5)
                            .foregroundStyle(selected ? .white : p.tint)
                            .background(selected ? p.tint : DS.Colors.chip, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .help(p.displayName)
                }
            }
        }
    }

    private var personPicker: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            HStack(spacing: DS.Space.s) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(DS.Colors.muted)
                TextField("Search people — name, handle, or phone…", text: $query)
                    .textFieldStyle(.plain).font(DS.Typography.body)
            }
            .padding(.horizontal, DS.Space.s).padding(.vertical, 6)
            .background(DS.Colors.card, in: Capsule())
            .overlay(Capsule().stroke(DS.Colors.hairline, lineWidth: 1))

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(matchingHits.prefix(6)) { hit in
                        Button { choose(hit) } label: {
                            HStack(spacing: DS.Space.s) {
                                AvatarView(name: hit.person.displayName, data: hit.person.avatarData, size: 22)
                                Text(hit.person.displayName).font(DS.Typography.body)
                                    .foregroundStyle(DS.Colors.ink).lineLimit(1)
                                Spacer()
                                HStack(spacing: 2) {
                                    ForEach(hit.platforms.prefix(3), id: \.self) { p in
                                        Image(systemName: p.symbolName).font(.system(size: 8))
                                            .foregroundStyle(p.tint)
                                    }
                                }
                            }
                            .padding(.vertical, 5).padding(.horizontal, DS.Space.xs)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    if matchingHits.isEmpty {
                        Text("No matches").font(DS.Typography.caption)
                            .foregroundStyle(DS.Colors.muted).padding(.vertical, 6)
                    }
                }
            }
            .frame(maxHeight: 168)
        }
        .padding(DS.Space.s)
        .background(DS.Colors.card.opacity(0.5), in: RoundedRectangle(cornerRadius: DS.Radius.l, style: .continuous))
    }

    /// Empty query shows the roster (existing status-ranked order); non-empty
    /// runs the real cross-platform search (name / contact name / handle /
    /// normalized phone digits) — a person textable on 3 platforms is one row.
    private var matchingHits: [OsmoStore.PersonHit] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else {
            return model.people.prefix(8).map { row in
                OsmoStore.PersonHit(person: Person(id: row.id, displayName: row.name, avatarData: row.avatar),
                                    contacts: [], platforms: row.platforms)
            }
        }
        return (try? model.store.searchPeople(q)) ?? []
    }

    private func choose(_ hit: OsmoStore.PersonHit) {
        overridePerson = hit.person
        hitPlatforms = hit.platforms
        overridePlatform = hit.platforms.first(where: { $0 == context.platform }) ?? hit.platforms.first
        withAnimation(DS.Motion.standard) { pickerOpen = false }
        query = ""
        resolve()
        draftVersion += 1   // re-draft grounded on the chosen person
    }

    // MARK: Tone + intent

    private var toneRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(ToneOption.allCases) { option in
                    let selected = selectedTone == option
                    Button {
                        selectedTone = option
                        resolve(); draftVersion += 1
                    } label: {
                        Text(option.rawValue).font(DS.Typography.eyebrow)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .foregroundStyle(selected ? .white : DS.Colors.ink)
                            .background(selected ? DS.Colors.accent : DS.Colors.chip, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var intentField: some View {
        HStack(spacing: DS.Space.s) {
            Image(systemName: "text.cursor").font(.system(size: 11)).foregroundStyle(DS.Colors.muted)
            TextField("Tell Osmo what you want to say…", text: $intent)
                .textFieldStyle(.plain)
                .font(DS.Typography.body)
                .onSubmit { applyIntent() }
            if intent != submittedIntent && !intent.isEmpty {
                Button { applyIntent() } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 15))
                }.buttonStyle(.plain).foregroundStyle(DS.Colors.accent)
            }
        }
        .padding(.horizontal, DS.Space.m)
        .padding(.vertical, DS.Space.s)
        .background(DS.Colors.card, in: Capsule())
        .overlay(Capsule().stroke(DS.Colors.hairline, lineWidth: 1))
    }

    // MARK: Draft box + send

    private var draftBox: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            Eyebrow("Your message")
                .onChange(of: draft) { _, _ in toneCheck = nil; analysis = nil }   // stale reads lie
            TextEditor(text: $draft)
                .font(DS.Typography.body).scrollContentBackground(.hidden)
                .frame(minHeight: 52, maxHeight: 108)
                .padding(DS.Space.s)
                .background(DS.Colors.card, in: RoundedRectangle(cornerRadius: DS.Radius.l, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.l, style: .continuous)
                    .stroke(DS.Colors.hairline, lineWidth: 1))
                .overlay(alignment: .topLeading) {
                    if draft.isEmpty {
                        Text("Take a suggestion above, or write your own…")
                            .font(DS.Typography.body).foregroundStyle(DS.Colors.muted)
                            .padding(.horizontal, DS.Space.s + 4).padding(.vertical, DS.Space.s + 2)
                            .allowsHitTesting(false)
                    }
                }
            if let check = toneCheck {
                ToneCheckResult(check: check)
            }
            HStack(spacing: DS.Space.s) {
                Button("Check") { runToneCheck() }
                    .font(DS.Typography.captionEm).buttonStyle(.plain).foregroundStyle(DS.Colors.accent)
                    .disabled(isDraftEmpty)
                    .help("How does this land? Instant read, no waiting — always free.")
                Spacer()
                // Mode-switching primary: nothing written yet → generate; once
                // there's a draft, the ask shifts to "is this good" → Analyze.
                if isDraftEmpty {
                    PillButton("Draft for me", icon: "sparkles") {
                        withAnimation(DS.Motion.standard) { showSuggestions = true }
                    }
                } else {
                    if analyzing {
                        ProgressView().controlSize(.small)
                    } else {
                        PillButton("Analyze", icon: "checkmark.seal", kind: .quiet) { analyze() }
                    }
                    Button("Copy") { copy(draft) }
                        .font(DS.Typography.captionEm).buttonStyle(.plain).foregroundStyle(DS.Colors.muted)
                    // Drop it straight into the compose box they were typing in —
                    // "you just have to click send".
                    if canInsertToField {
                        PillButton("Insert", icon: "text.insert",
                                   kind: canDirectSend ? .quiet : .primary) { insertToField() }
                    }
                    // One-click real send when there's a live target (iMessage
                    // always; connected platforms when active).
                    if canDirectSend {
                        PillButton("Send", icon: "paperplane.fill") { sendDirect() }
                    }
                }
            }
        }
    }

    private var isDraftEmpty: Bool {
        draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    private var canInsertToField: Bool { PillController.shared.focusedElement != nil }
    private var canDirectSend: Bool {
        model.connections.canDirectSend(platform) && !(resolved?.target.isEmpty ?? true)
    }

    // MARK: Resolve + actions

    /// Resolve the suggestion context + send target ONCE (synchronous store reads).
    /// When the user has picked a specific person, ground on their real thread.
    private func resolve() {
        let assembler = ContextAssembler(store: model.store, projects: model.projects,
                                         selfPreamble: model.onboardingProfile.promptPreamble)
        if let person = overridePerson, let threadID = bestThread(for: person) {
            var ctx = assembler.context(threadID: threadID, platform: platform,
                                        personName: person.displayName, toneOverride: selectedTone.hint)
            if !submittedIntent.isEmpty { ctx.userIntent = submittedIntent }
            resolved = (ctx, assembler.sendTarget(threadID: threadID, platform: platform))
            return
        }
        var ctx = assembler.context(pill: context, toneOverride: selectedTone.hint)
        if !submittedIntent.isEmpty { ctx.userIntent = submittedIntent }
        let threadID = context.matchedThreadID
            ?? assembler.matchThread(name: context.partnerName, platform: platform)
        let target = threadID.map { assembler.sendTarget(threadID: $0, platform: platform) } ?? ""
        resolved = (ctx, target)
    }

    /// The chosen person's most relevant thread — same platform if any, else most
    /// recent (model.threads is ordered newest-first).
    private func bestThread(for person: Person) -> UUID? {
        let contactIDs = Set(((try? model.store.contacts(forPerson: person.id)) ?? []).map(\.id))
        let matching = model.threads.filter { thread in
            let tc = (try? model.store.contacts(inThread: thread.id)) ?? []
            return tc.contains { contactIDs.contains($0.id) }
        }
        return (matching.first { $0.platform == platform } ?? matching.first)?.id
    }

    private func applyIntent() {
        guard intent != submittedIntent else { return }
        submittedIntent = intent
        resolve()
        draftVersion += 1
    }

    /// Drop the text straight into the compose box they were typing in, then
    /// collapse — "you just have to click send".
    private func insertToField() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        PillController.shared.insertIntoFocusedField(text)
        PillController.shared.escape()
    }

    /// One-click real send through the live connection (iMessage AppleScript, or a
    /// connected platform). Falls back to inserting into the field if it fails.
    private func sendDirect() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let resolved else { return }
        Task {
            let ok = await model.send(text, platform: platform, target: resolved.target)
            await MainActor.run {
                if !ok { PillController.shared.insertIntoFocusedField(text) }
                PillController.shared.escape()
            }
        }
    }

    private func runToneCheck() {
        guard let resolved else { return }
        toneCheck = ToneCheck.check(draft: draft,
                                    partner: PartnerProfile.read(resolved.context.transcript),
                                    read: ThreadRead.read(resolved.context.transcript))
    }

    /// User-initiated, so the metered-allowance paywall side effect is correct
    /// here (unlike the background autodraft path, which never pops it).
    private func analyze() {
        guard !isDraftEmpty, let resolved, model.requestDraftAllowance() else { return }
        analyzing = true
        let partner = PartnerProfile.read(resolved.context.transcript)
        let judgeCtx = JudgeContext(
            draft: draft, personName: partnerName, platform: platform,
            toneHint: resolved.context.toneHint,
            userIntent: submittedIntent.isEmpty ? nil : submittedIntent,
            partnerDirectives: partner.directives, goalText: resolved.context.goalText,
            transcript: Array(resolved.context.transcript.suffix(12)))
        let check = ToneCheck.check(draft: draft, partner: partner,
                                    read: ThreadRead.read(resolved.context.transcript))
        Task {
            let result = try? await model.service.judge(judgeCtx)
            await MainActor.run {
                analyzing = false
                guard let result else { return }
                analysis = MessageJudge.merge(result, toneCheck: check)
            }
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// The Analyze result: a score ring, WHY IT WORKS / RISKS columns, and
/// alternative rewrites with Use/Copy. Dismissible; cleared on any draft edit.
struct AnalysisView: View {
    let result: MessageJudge.Result
    var onUse: (String) -> Void
    var onClear: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            HStack(spacing: DS.Space.m) {
                ScoreRing(score: result.score ?? 0)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verdictWord).font(DS.Typography.bodyEm).foregroundStyle(DS.Colors.ink)
                    if let score = result.score {
                        Text("\(score)/10").font(DS.Typography.caption).foregroundStyle(DS.Colors.muted)
                    }
                }
                Spacer()
                Button { onClear() } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .medium))
                }
                .buttonStyle(.plain).foregroundStyle(DS.Colors.muted)
            }
            if !result.works.isEmpty || !result.risks.isEmpty {
                HStack(alignment: .top, spacing: DS.Space.l) {
                    if !result.works.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Eyebrow("Why it works")
                            ForEach(result.works, id: \.self) { w in
                                Label(w, systemImage: "checkmark.circle")
                                    .font(DS.Typography.caption).foregroundStyle(DS.Colors.ink)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if !result.risks.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Eyebrow("Risks")
                            ForEach(result.risks, id: \.self) { r in
                                Label(r, systemImage: "lightbulb")
                                    .font(DS.Typography.caption).foregroundStyle(DS.Colors.muted)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            if !result.alternatives.isEmpty {
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    Eyebrow("Try instead")
                    ForEach(result.alternatives, id: \.label) { alt in
                        alternativeCard(alt)
                    }
                }
            }
        }
        .padding(DS.Space.m)
        .background(DS.Colors.card, in: RoundedRectangle(cornerRadius: DS.Radius.l, style: .continuous))
    }

    private var verdictWord: String {
        guard let score = result.score else { return "Take a look" }
        if score >= 8 { return "Send it" }
        if score >= 5 { return "Solid — small tweaks" }
        return "Worth a rework"
    }

    private func alternativeCard(_ alt: MessageJudge.Alternative) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(alt.label.uppercased()).font(DS.Typography.eyebrow).foregroundStyle(DS.Colors.accent)
            Text(alt.text).font(DS.Typography.body).foregroundStyle(DS.Colors.ink)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: DS.Space.s) {
                Button("Use") { onUse(alt.text) }
                    .font(DS.Typography.captionEm).buttonStyle(.plain).foregroundStyle(DS.Colors.accent)
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(alt.text, forType: .string)
                }
                .font(DS.Typography.captionEm).buttonStyle(.plain).foregroundStyle(DS.Colors.muted)
            }
        }
        .padding(DS.Space.s)
        .background(DS.Colors.paper, in: RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous)
            .stroke(DS.Colors.hairlineSoft, lineWidth: 1))
    }
}

/// A trimmed circle + big numeral — the score at a glance. Color rides the
/// same three-tier read as the verdict word (red/amber/green).
struct ScoreRing: View {
    let score: Int   // 0...10
    private var progress: Double { Double(max(0, min(10, score))) / 10 }
    private var color: Color {
        if score >= 8 { return DS.Colors.green }
        if score >= 5 { return DS.Colors.amber }
        return DS.Colors.red
    }

    var body: some View {
        ZStack {
            Circle().stroke(DS.Colors.hairline, lineWidth: 4)
            Circle().trim(from: 0, to: progress)
                .stroke(color, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(score)").font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundStyle(DS.Colors.ink)
        }
        .frame(width: 44, height: 44)
    }
}
