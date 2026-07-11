import SwiftUI
import OsmoCore
import OsmoBrain

/// The three-takes surface — the product's core moment, reused by the pill and
/// the inbox thread detail. Runs the suggestion service, renders each take with
/// its "why it works", and offers Send/Insert/Copy per dynamic capability. A
/// demo-mode chip appears when the takes come from the keyless mock.
struct SuggestionStrip: View {
    @EnvironmentObject var model: AppModel

    let context: SuggestionContext
    let platform: Platform
    /// Where a direct send routes (thread id / handle). Empty → copy/insert.
    var sendTarget: String
    /// iMessage groups can't direct-send (one buddy handle can't address a
    /// group) — passed through so `send()` takes the honest copy-fallback
    /// path instead of silently mis-delivering to one member.
    var isGroup: Bool = false
    /// Called when a take is chosen for editing (fills a compose box).
    var onPick: ((String) -> Void)?
    /// Called after a successful send.
    var onSent: (() -> Void)?

    @State private var takes: [SuggestionTake] = []
    @State private var loading = true
    @State private var error: String?
    @State private var sentSlant: SuggestionTake.Slant?
    @State private var isMock = false
    @State private var tone: String?

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            HStack(spacing: DS.Space.s) {
                Eyebrow("Three ways to say it")
                if isMock {
                    Text("DEMO").font(DS.Typography.eyebrow)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(DS.Colors.chip, in: Capsule())
                        .foregroundStyle(DS.Colors.muted)
                }
                Spacer()
                toneMenu
                Button(action: { draft() }) {
                    Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.plain).foregroundStyle(DS.Colors.muted)
                .accessibilityLabel("Regenerate")
            }

            if loading {
                ForEach(0..<3, id: \.self) { _ in skeletonRow }
            } else if let error {
                Text(error).font(DS.Typography.body).foregroundStyle(DS.Colors.muted)
            } else {
                ForEach(takes) { take in takeRow(take) }
            }
        }
        .task { draft() }
    }

    private var toneMenu: some View {
        Menu {
            Button("Balanced") { tone = nil; draft() }
            Button("Warmer") { tone = "warmer, more personal"; draft() }
            Button("Shorter") { tone = "much shorter and to the point"; draft() }
            Button("More direct") { tone = "more direct and confident"; draft() }
        } label: {
            HStack(spacing: 2) {
                Image(systemName: "slider.horizontal.3").font(.system(size: 10))
                Text(tone == nil ? "Tone" : "Tone ·").font(DS.Typography.eyebrow)
            }
            .foregroundStyle(DS.Colors.muted)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func takeRow(_ take: SuggestionTake) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            Text(take.slant.label.uppercased())
                .font(DS.Typography.eyebrow).tracking(0.6).foregroundStyle(DS.Colors.accent)
            Text(take.text)
                .font(DS.Typography.body).foregroundStyle(DS.Colors.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            if let why = take.whyItWorks {
                Text(why).font(DS.Typography.caption).foregroundStyle(DS.Colors.muted).lineLimit(2)
            }
            HStack(spacing: DS.Space.s) {
                if sentSlant == take.slant {
                    Label("Sent", systemImage: "checkmark")
                        .font(DS.Typography.captionEm).foregroundStyle(DS.Colors.accent)
                } else if canSend {
                    PillButton("Send", icon: "paperplane.fill") { send(take) }
                } else {
                    PillButton("Insert", icon: "text.insert", kind: .quiet) { insert(take.text) }
                }
                if let onPick {
                    Button("Edit") { onPick(take.text) }
                        .font(DS.Typography.captionEm).buttonStyle(.plain).foregroundStyle(DS.Colors.muted)
                }
                Button("Copy") { copy(take.text) }
                    .font(DS.Typography.captionEm).buttonStyle(.plain).foregroundStyle(DS.Colors.muted)
            }
            .padding(.top, 2)
        }
        .padding(DS.Space.m)
        .background(DS.Colors.card, in: RoundedRectangle(cornerRadius: DS.Radius.l, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.l, style: .continuous)
            .stroke(DS.Colors.hairlineSoft, lineWidth: 1))
    }

    private var skeletonRow: some View {
        RoundedRectangle(cornerRadius: DS.Radius.l, style: .continuous)
            .fill(DS.Colors.card)
            .frame(height: 68)
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.l, style: .continuous)
                .stroke(DS.Colors.hairlineSoft, lineWidth: 1))
            .redacted(reason: .placeholder)
    }

    private var canSend: Bool {
        model.connections.canDirectSend(platform) && !sendTarget.isEmpty
    }

    private func draft() {
        // The metered thing: every AI draft passes through here (pill, inbox
        // assist, Today). Free tier gets a weekly allowance; the cap opens the
        // paywall instead of silently failing.
        guard model.requestDraftAllowance() else {
            error = "You're out of free drafts this week — Osmo Pro is unlimited."
            loading = false
            return
        }
        loading = true; error = nil
        let ctx = tone == nil ? context : withTone(context, tone!)
        Task {
            do {
                let result = try await model.service.suggest(ctx)
                await MainActor.run {
                    takes = result.set.takes
                    isMock = result.set.takes.first?.text.contains("[mock]") ?? false
                    loading = false
                }
            } catch let GenerationError.refusedBySafety(reason) {
                await MainActor.run { error = reason; loading = false }
            } catch {
                await MainActor.run { self.error = "Couldn't draft — try again."; loading = false }
            }
        }
    }

    private func withTone(_ ctx: SuggestionContext, _ tone: String) -> SuggestionContext {
        var copy = ctx
        copy.toneHint = [ctx.toneHint, tone].compactMap { $0 }.joined(separator: ", ")
        return copy
    }

    private func send(_ take: SuggestionTake) {
        if platform == .x, take.text.count > 1_000 {
            model.toast = "That draft is over X's 1,000-character DM limit — copy and trim it instead."
            copy(take.text)
            return
        }
        Task {
            let ok = await model.send(take.text, platform: platform, target: sendTarget, isGroup: isGroup)
            await MainActor.run {
                if ok { sentSlant = take.slant; onSent?() } else { copy(take.text) }
            }
        }
    }

    private func insert(_ text: String) {
        // Red platforms: copy so the user pastes into the real compose box.
        copy(text)
        onPick?(text)
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
