import SwiftUI
import OsmoCore
import OsmoBrain

// MARK: Morning Queue

struct MorningQueueView: View {
    @EnvironmentObject var model: AppModel
    @State private var active: QueueCard?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header("Morning", subtitle: model.queue.isEmpty ? "You're clear ✦" : "\(model.queue.count) to attend to")
                if model.queue.isEmpty {
                    emptyState("Nothing owed. Enjoy the quiet.")
                } else {
                    ForEach(model.queue) { card in queueCard(card) }
                }
            }
            .padding(24)
        }
        .sheet(item: $active) { card in
            SuggestionPanel(context: cardContext(card), personName: card.personName,
                            platform: card.platform,
                            sendTarget: model.threads.first { $0.id == card.threadID }?.platformThreadID ?? "")
                .environmentObject(model)
                .frame(width: 460)
        }
    }

    private func queueCard(_ card: QueueCard) -> some View {
        HStack(spacing: 12) {
            Avatar(name: card.personName, data: nil, size: 44)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(card.personName).font(.osmoTitle)
                    StatusPill(status: card.status)
                }
                Text(card.reason).font(.osmoBody).foregroundStyle(Theme.muted).lineLimit(2)
            }
            Spacer()
            Button("Draft") { active = card }.buttonStyle(PillButton())
        }
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.hairline, lineWidth: 1))
    }

    private func cardContext(_ card: QueueCard) -> SuggestionContext {
        let project = card.projectID.flatMap { pid in model.projects.first { $0.id == pid } }
        let memory = card.personID.flatMap { try? model.store.memory(forPerson: $0) }
        let transcript = (try? model.store.messages(inThread: card.threadID))?.suffix(20).map {
            ThreadTurn(fromMe: $0.isFromMe, text: $0.text, sentAt: $0.sentAt)
        } ?? []
        return SuggestionContext(
            relationshipLabel: project?.title ?? card.personName,
            platform: card.platform,
            goalText: project?.goalText, toneHint: project?.toneHint,
            boundaries: project?.boundaries ?? [], selfContext: project?.selfContext,
            relationshipMemory: memory?.promptContext,
            transcript: transcript, userIntent: card.suggestedMove)
    }
}

// MARK: People

struct PeopleView: View {
    @EnvironmentObject var model: AppModel
    private let cols = [GridItem(.adaptive(minimum: 140), spacing: 16)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header("People", subtitle: "\(model.people.count) tracked")
                LazyVGrid(columns: cols, alignment: .leading, spacing: 20) {
                    ForEach(model.people) { person in
                        VStack(spacing: 8) {
                            Avatar(name: person.name, data: person.avatar, size: 72)
                                .overlay(alignment: .bottom) { StatusPill(status: person.status).offset(y: 10) }
                                .padding(.bottom, 8)
                            Text(person.name).font(.osmoBody).lineLimit(1)
                            Text(person.platforms.map(\.displayName).joined(separator: " · "))
                                .font(.osmoCaption).foregroundStyle(Theme.muted).lineLimit(1)
                        }
                    }
                }
            }
            .padding(24)
        }
    }
}

// MARK: Projects

struct ProjectsView: View {
    @EnvironmentObject var model: AppModel
    @State private var creating = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    header("Projects", subtitle: "goal-directed relationships")
                    Spacer()
                    Button { creating = true } label: { Label("New", systemImage: "plus") }
                        .buttonStyle(PillButton())
                }
                if model.projects.isEmpty {
                    emptyState("No projects yet. Set a goal with someone who matters.")
                } else {
                    ForEach(model.projects) { p in projectCard(p) }
                }
            }
            .padding(24)
        }
        .sheet(isPresented: $creating) { NewProjectSheet().environmentObject(model) }
    }

    private func projectCard(_ p: Project) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(p.title).font(.osmoTitle)
            Text(p.goalText).font(.osmoBody).foregroundStyle(Theme.muted)
            if let tone = p.toneHint { Text("Tone: \(tone)").font(.osmoCaption).foregroundStyle(Theme.gold) }
            if !p.boundaries.isEmpty {
                Text("Never: \(p.boundaries.joined(separator: ", "))")
                    .font(.osmoCaption).foregroundStyle(Theme.muted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.hairline, lineWidth: 1))
    }
}

struct NewProjectSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var goal = ""
    @State private var tone = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New project").font(.osmoTitle)
            TextField("Title (e.g. Land the Acme deal)", text: $title)
            TextField("Goal (e.g. get them to sign by Q3)", text: $goal)
            TextField("Tone (optional)", text: $tone)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Create") {
                    try? model.store.put(Project(personID: UUID(), title: title, goalText: goal,
                                                 toneHint: tone.isEmpty ? nil : tone))
                    model.reload(); dismiss()
                }
                .buttonStyle(PillButton())
                .disabled(title.isEmpty || goal.isEmpty)
            }
        }
        .padding(20).frame(width: 420)
    }
}

// MARK: Inbox

struct InboxView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                header("Inbox", subtitle: "every platform, one timeline")
                TextField("Search all messages…", text: $model.searchText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.runSearch() }
                if !model.searchResults.isEmpty {
                    ForEach(model.searchResults) { m in messageRow(m) }
                } else {
                    ForEach(model.threads) { t in threadRow(t) }
                }
            }
            .padding(24)
        }
    }

    private func threadRow(_ t: OsmoThread) -> some View {
        let last = try? model.store.lastMessage(inThread: t.id)
        return HStack(spacing: 10) {
            Text(t.platform.displayName.prefix(1)).font(.osmoCaption).foregroundStyle(Theme.muted)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(t.title ?? "Conversation").font(.osmoBody)
                Text(last?.text ?? "").font(.osmoCaption).foregroundStyle(Theme.muted).lineLimit(1)
            }
            Spacer()
        }
        .padding(.vertical, 6)
    }

    private func messageRow(_ m: OsmoMessage) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(m.isFromMe ? "You" : "Them").font(.osmoEyebrow).foregroundStyle(Theme.muted)
            Text(m.text).font(.osmoBody).lineLimit(2)
        }
        .padding(.vertical, 6)
    }
}

// MARK: Shared

func header(_ title: String, subtitle: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
        Text(title).font(.osmoDisplay).foregroundStyle(Theme.ink)
        Text(subtitle).font(.osmoBody).foregroundStyle(Theme.muted)
    }
}

func emptyState(_ text: String) -> some View {
    Text(text).font(.osmoBody).foregroundStyle(Theme.muted)
        .frame(maxWidth: .infinity, minHeight: 200)
}
