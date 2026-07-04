import SwiftUI
import OsmoCore
import OsmoBrain

/// The three-takes surface, reused by the morning queue and the overlay. Runs the
/// suggestion service (keyless mock until credentials land), shows each take with
/// its "why this works", and offers Send vs Insert per the platform split.
struct SuggestionPanel: View {
    @EnvironmentObject var model: AppModel
    let context: SuggestionContext
    let personName: String
    let platform: Platform
    /// Where a direct send goes (iMessage handle, Slack channel, email). Empty
    /// when unknown → the button copies instead.
    var sendTarget: String = ""

    @State private var takes: [SuggestionTake] = []
    @State private var loading = true
    @State private var error: String?
    @State private var sentSlant: SuggestionTake.Slant?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(personName).font(.osmoTitle)
                Spacer()
                Text(platform.displayName).font(.osmoCaption).foregroundStyle(Theme.muted)
            }
            if let context = context.goalText {
                Text("Goal: \(context)").font(.osmoCaption).foregroundStyle(Theme.gold)
            }

            if loading {
                ProgressView().frame(maxWidth: .infinity).padding()
            } else if let error {
                Text(error).font(.osmoBody).foregroundStyle(Theme.muted)
            } else {
                ForEach(takes) { take in takeCard(take) }
            }

            Button(action: draft) {
                Label("Redraft", systemImage: "arrow.clockwise").font(.osmoCaption)
            }
            .buttonStyle(.plain).foregroundStyle(Theme.muted)
        }
        .padding(16)
        .task { draft() }
    }

    private func takeCard(_ take: SuggestionTake) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(take.slant.label.uppercased()).font(.osmoEyebrow).foregroundStyle(Theme.muted)
            Text(take.text).font(.osmoBody).foregroundStyle(Theme.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let why = take.whyItWorks {
                Text(why).font(.osmoCaption).foregroundStyle(Theme.muted).lineLimit(2)
            }
            HStack {
                if sentSlant == take.slant {
                    Text("Sent ✓").font(.osmoCaption.weight(.semibold)).foregroundStyle(Theme.gold)
                } else if platform.supportsDirectSend {
                    Button("Send") { send(take) }.buttonStyle(PillButton())
                } else {
                    Button("Insert & review") { insert(take.text) }.buttonStyle(PillButton())
                }
                Button("Copy") { copy(take.text) }.buttonStyle(.plain).foregroundStyle(Theme.muted)
            }
        }
        .padding(12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.hairline, lineWidth: 1))
    }

    private func draft() {
        loading = true; error = nil
        Task {
            do {
                let result = try await model.service.suggest(context)
                await MainActor.run { takes = result.set.takes; loading = false }
            } catch let GenerationError.refusedBySafety(reason) {
                await MainActor.run { error = reason; loading = false }
            } catch {
                await MainActor.run { self.error = "Couldn't draft — try again."; loading = false }
            }
        }
    }

    /// Direct send (iMessage lands via AppleScript on this Mac). If the platform
    /// can't send yet (no token, or a red platform), we copy so the user can paste.
    private func send(_ take: SuggestionTake) {
        Task {
            let ok = sendTarget.isEmpty ? false
                : await model.send(take.text, platform: platform, target: sendTarget)
            await MainActor.run {
                if ok { sentSlant = take.slant } else { copy(take.text) }
            }
        }
    }

    /// Red platforms: put the draft on the pasteboard so the user pastes it into
    /// the real compose box and hits Return (one keystroke from sent).
    private func insert(_ text: String) { copy(text) }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

struct PillButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.osmoCaption.weight(.semibold))
            .foregroundStyle(Theme.onAccent)
            .padding(.horizontal, 14).padding(.vertical, 6)
            .background(Theme.accent, in: Capsule())
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}
