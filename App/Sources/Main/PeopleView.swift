import SwiftUI
import OsmoCore

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
                    if !model.mergeSuggestions.isEmpty {
                        Section("Review") {
                            ForEach(Array(model.mergeSuggestions.enumerated()), id: \.offset) { _, suggestion in
                                MergeSuggestionRow(suggestion: suggestion)
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
                Button("Not the same") { /* rejected-pair persistence: P1 */ }
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
        guard personIDs.count >= 2 else { return }
        _ = try? model.store.mergePeople(personIDs)
        model.reload()
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
        case .ghosted: return "Quiet"
        case .quiet: return "Quiet"
        case .sayHi: return "Say hi"
        }
    }
}

/// Person detail: header + cross-platform timeline + editable memory.
struct PersonDetailView: View {
    @EnvironmentObject var model: AppModel
    let person: PersonRow

    @State private var note: String = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.xl) {
                header
                memoryEditor
                timeline
            }
            .padding(DS.Space.xl)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .onAppear { note = (try? model.store.memory(forPerson: person.id))?.note ?? "" }
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
            ForEach(threads) { thread in
                Button {
                    model.selectedThreadID = thread.id
                    model.section = .inbox
                } label: {
                    Card {
                        HStack {
                            Image(systemName: thread.platform.symbolName)
                                .font(.system(size: 12)).foregroundStyle(thread.platform.tint)
                            Text((try? model.store.lastMessage(inThread: thread.id))?.text ?? "")
                                .font(DS.Typography.body).foregroundStyle(DS.Colors.ink).lineLimit(1)
                            Spacer()
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var threads: [OsmoThread] {
        let contacts = (try? model.store.contacts(forPerson: person.id)) ?? []
        let contactIDs = Set(contacts.map(\.id))
        return model.threads.filter { thread in
            let threadContacts = (try? model.store.contacts(inThread: thread.id)) ?? []
            return threadContacts.contains { contactIDs.contains($0.id) } || thread.id == person.id
        }
    }

    private func saveNote(_ text: String) {
        var memory = (try? model.store.memory(forPerson: person.id))
            ?? RelationshipMemory(personID: person.id)
        memory.note = text
        memory.updatedAt = Date()
        try? model.store.put(memory)
    }
}
