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

/// The small always-present pill. Tap to expand; drag to reposition.
struct CollapsedPill: View {
    enum Kind { case idle, ready }
    let kind: Kind
    let matched: String?
    let controller: PillController

    @State private var dragging = false

    var body: some View {
        HStack(spacing: DS.Space.s) {
            Image(systemName: "sparkles")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(DS.Colors.accent)
            if kind == .ready, let matched {
                Text(matched).font(DS.Typography.captionEm).foregroundStyle(DS.Colors.ink)
                    .lineLimit(1)
                Text("⌥Space").font(DS.Typography.eyebrow).foregroundStyle(DS.Colors.muted)
            } else {
                Text("Osmo").font(DS.Typography.captionEm).foregroundStyle(DS.Colors.ink)
            }
        }
        .padding(.horizontal, DS.Space.m)
        .padding(.vertical, DS.Space.s)
        .frame(height: 36)
        .background(GlassSurface(shape: Capsule()))
        .clipShape(Capsule())
        .overlay(Capsule().stroke(kind == .ready ? DS.Colors.accent.opacity(0.4) : DS.Colors.glassBorder, lineWidth: 1))
        .shadow(color: DS.Colors.shadow, radius: 12, x: 0, y: 4)
        .contentShape(Capsule())
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
        .accessibilityLabel(matched.map { "Osmo — draft a reply to \($0)" } ?? "Osmo — draft a reply")
    }

    @State private var lastX: CGFloat = 0
    @State private var lastY: CGFloat = 0
}

/// The expanded panel: three takes + an intent field, in glass.
struct ExpandedPanel: View {
    @EnvironmentObject var model: AppModel
    let context: PillContext
    let generating: Bool

    @State private var intent: String = ""

    var body: some View {
        GlassCard(cornerRadius: DS.Radius.xxl) {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                header
                if let ctx = suggestionContext {
                    SuggestionStrip(
                        context: ctx,
                        platform: context.platform ?? .imessage,
                        sendTarget: sendTarget,
                        onPick: { text in insert(text) },
                        onSent: { PillController.shared.escape() })
                        .environmentObject(model)
                        .id(intentKey)   // re-draft when intent changes
                }
                intentField
            }
            .padding(DS.Space.l)
            .frame(width: 420)
        }
        .onExitCommand { PillController.shared.escape() }
    }

    private var header: some View {
        HStack {
            if let platform = context.platform {
                Image(systemName: platform.symbolName).font(.system(size: 12))
                    .foregroundStyle(platform.tint)
            }
            Text(context.partnerName ?? "Draft a reply")
                .font(DS.Typography.title).foregroundStyle(DS.Colors.ink)
            Spacer()
            Button { PillController.shared.escape() } label: {
                Image(systemName: "xmark").font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.plain).foregroundStyle(DS.Colors.muted)
            .accessibilityLabel("Close")
        }
    }

    private var intentField: some View {
        HStack(spacing: DS.Space.s) {
            Image(systemName: "text.cursor").font(.system(size: 11)).foregroundStyle(DS.Colors.muted)
            TextField("Tell Osmo what you want to say…", text: $intent)
                .textFieldStyle(.plain)
                .font(DS.Typography.body)
                .onSubmit { /* intentKey change re-drafts the strip */ }
        }
        .padding(.horizontal, DS.Space.m)
        .padding(.vertical, DS.Space.s)
        .background(DS.Colors.card, in: Capsule())
        .overlay(Capsule().stroke(DS.Colors.hairline, lineWidth: 1))
    }

    private var intentKey: String { intent }

    private var suggestionContext: SuggestionContext? {
        let assembler = ContextAssembler(store: model.store, projects: model.projects)
        var ctx = assembler.context(pill: context)
        if !intent.isEmpty { ctx.userIntent = intent }
        return ctx
    }

    private var sendTarget: String {
        guard let threadID = context.matchedThreadID
                ?? ContextAssembler(store: model.store, projects: model.projects)
                    .matchThread(name: context.partnerName, platform: context.platform ?? .imessage)
        else { return "" }
        return ContextAssembler(store: model.store, projects: model.projects)
            .sendTarget(threadID: threadID, platform: context.platform ?? .imessage)
    }

    private func insert(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
