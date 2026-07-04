import SwiftUI
import OsmoCore

/// Projects — the wedge: a goal + tone + boundaries per person that steers every
/// suggestion. List of project cards → an editor.
struct ProjectsView: View {
    @EnvironmentObject var model: AppModel
    @State private var editing: Project?
    @State private var creating = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.l) {
                HStack {
                    VStack(alignment: .leading, spacing: DS.Space.xs) {
                        Eyebrow("Advance each relationship")
                        Text("Projects").font(DS.Typography.display).foregroundStyle(DS.Colors.ink)
                    }
                    Spacer()
                    PillButton("New project", icon: "plus") { creating = true }
                }

                if model.projects.isEmpty {
                    EmptyStateView(icon: "target", title: "No projects yet",
                                   message: "Set a goal and tone for someone — Osmo drafts every reply toward it.",
                                   cta: ("New project", { creating = true }))
                } else {
                    ForEach(model.projects) { project in
                        Button { editing = project } label: { ProjectCard(project: project) }
                            .buttonStyle(.plain)
                    }
                }
            }
            .padding(DS.Space.xl)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .sheet(item: $editing) { project in
            ProjectEditor(project: project).environmentObject(model)
        }
        .sheet(isPresented: $creating) {
            ProjectEditor(project: nil).environmentObject(model)
        }
    }
}

struct ProjectCard: View {
    @EnvironmentObject var model: AppModel
    let project: Project
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                HStack {
                    Text(project.title).font(DS.Typography.heading).foregroundStyle(DS.Colors.ink)
                    Spacer()
                    if let tone = project.toneHint { Chip(tone) }
                }
                Text(project.goalText).font(DS.Typography.body).foregroundStyle(DS.Colors.muted).lineLimit(2)
            }
        }
    }
}

/// Create / edit a project.
struct ProjectEditor: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    let project: Project?

    @State private var title = ""
    @State private var goal = ""
    @State private var tone = ""
    @State private var selfContext = ""
    @State private var personID: UUID?
    @State private var boundaries: [String] = []
    @State private var newBoundary = ""

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.l) {
            Text(project == nil ? "New project" : "Edit project").font(DS.Typography.title)

            field("Title", text: $title)
            personPicker
            field("Goal", text: $goal, prompt: "e.g. land a coffee chat")
            field("Tone", text: $tone, prompt: "warm but professional")
            boundaryEditor
            field("About you (context)", text: $selfContext, prompt: "anything Osmo should know about your side")

            HStack {
                if project != nil {
                    Button("Delete", role: .destructive) { delete() }
                        .foregroundStyle(DS.Colors.red)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                PillButton("Save") { save() }.disabled(title.isEmpty || goal.isEmpty)
            }
        }
        .padding(DS.Space.xl)
        .frame(width: 480)
        .background(DS.Colors.paper)
        .onAppear { load() }
    }

    private var personPicker: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            Eyebrow("Person")
            Picker("", selection: $personID) {
                Text("—").tag(UUID?.none)
                ForEach(model.people) { person in
                    Text(person.name).tag(UUID?.some(person.id))
                }
            }
            .labelsHidden()
        }
    }

    private var boundaryEditor: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            Eyebrow("Boundaries (never do)")
            ForEach(boundaries, id: \.self) { b in
                HStack {
                    Text("• \(b)").font(DS.Typography.caption)
                    Spacer()
                    Button { boundaries.removeAll { $0 == b } } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).foregroundStyle(DS.Colors.muted)
                }
            }
            HStack {
                TextField("Add a boundary…", text: $newBoundary).textFieldStyle(.roundedBorder)
                Button("Add") {
                    if !newBoundary.isEmpty { boundaries.append(newBoundary); newBoundary = "" }
                }
            }
        }
    }

    private func field(_ label: String, text: Binding<String>, prompt: String = "") -> some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            Eyebrow(label)
            TextField(prompt, text: text).textFieldStyle(.roundedBorder)
        }
    }

    private func load() {
        guard let project else { return }
        title = project.title; goal = project.goalText; tone = project.toneHint ?? ""
        selfContext = project.selfContext ?? ""; personID = project.personID
        boundaries = project.boundaries
    }

    private func save() {
        var p = project ?? Project(
            id: UUID(), updatedAt: Date(), deviceSeq: 0,
            personID: personID ?? UUID(), title: title, goalText: goal,
            toneHint: tone.isEmpty ? nil : tone, boundaries: boundaries,
            selfContext: selfContext.isEmpty ? nil : selfContext,
            milestones: [], status: .active, createdAt: Date())
        p.title = title; p.goalText = goal
        p.toneHint = tone.isEmpty ? nil : tone
        p.selfContext = selfContext.isEmpty ? nil : selfContext
        p.boundaries = boundaries
        if let personID { p.personID = personID }
        p.updatedAt = Date()
        try? model.store.put(p)
        model.reload()
        dismiss()
    }

    private func delete() {
        guard let project else { return }
        try? model.store.softDelete(Project.self, id: project.id)
        model.reload()
        dismiss()
    }
}
