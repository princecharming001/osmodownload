import Foundation
import OsmoCore
import OsmoBrain
import OsmoShell

/// Builds a full `SuggestionContext` for the brain from whatever we know — a
/// real thread id (inbox/queue), or a detected pill context (partner name +
/// platform + draft). The one place transcript + memory + project get stitched
/// into the prompt, reused by the pill, the inbox detail, and the morning queue.
@MainActor
struct ContextAssembler {
    let store: OsmoStore
    let projects: [Project]
    /// The user's onboarding context layer rendered as a preamble ("They're using
    /// Osmo to… They want to come across as…"), merged into `selfContext` so every
    /// draft is framed for who they are — even before a per-person project exists.
    var selfPreamble: String = ""

    /// Merge the global onboarding preamble with any per-person project self-note.
    private func mergedSelf(_ projectSelf: String?) -> String? {
        let parts = [selfPreamble, projectSelf].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// From a real thread the app already has.
    func context(threadID: UUID, platform: Platform, personName: String,
                 userIntent: String? = nil, toneOverride: String? = nil) -> SuggestionContext {
        let contacts = (try? store.contacts(inThread: threadID)) ?? []
        let personID = contacts.first?.personID
        let project = personID.flatMap { pid in projects.first { $0.personID == pid } }
        let memory = personID.flatMap { try? store.memory(forPerson: $0) }
        let transcript = ((try? store.messages(inThread: threadID)) ?? [])
            .suffix(20)
            .map { ThreadTurn(fromMe: $0.isFromMe, text: $0.text, sentAt: $0.sentAt) }
        // Public identity (enrichment) — a draft to a VC shouldn't read like
        // one to a gym buddy.
        let enrichment = personID.flatMap { try? store.enrichment(forPerson: $0) }
        let background = enrichment.flatMap { e -> String? in
            guard let role = e.roleLine else { return nil }
            return e.location.map { "\(role), \($0)" } ?? role
        }
        return SuggestionContext(
            relationshipLabel: project?.title ?? personName,
            platform: platform,
            goalText: project?.goalText,
            toneHint: toneOverride ?? project?.toneHint,
            boundaries: project?.boundaries ?? [],
            selfContext: mergedSelf(project?.selfContext),
            relationshipMemory: memory?.promptContext,
            transcript: transcript,
            userIntent: userIntent,
            partnerBackground: background)
    }

    /// From a detected pill context. If we can fuzzy-match the partner to a known
    /// thread, we thread it through the real-thread path (full transcript); else
    /// a thin context (the brain handles an empty transcript).
    func context(pill: PillContext, toneOverride: String? = nil) -> SuggestionContext {
        let platform = pill.platform ?? .imessage

        if let threadID = pill.matchedThreadID ?? matchThread(name: pill.partnerName, platform: platform) {
            let name = pill.partnerName ?? "them"
            let intent = pill.draftText.flatMap { draft in
                draft.isEmpty ? nil : "Continue or refine this draft: \(draft)"
            }
            return context(threadID: threadID, platform: platform, personName: name,
                           userIntent: intent, toneOverride: toneOverride)
        }

        // No match — thin context.
        let intent = pill.draftText.flatMap { $0.isEmpty ? nil : "Continue or refine this draft: \($0)" }
        return SuggestionContext(
            relationshipLabel: pill.partnerName ?? "them",
            platform: platform,
            toneHint: toneOverride,
            selfContext: mergedSelf(nil),
            userIntent: intent)
    }

    /// Fuzzy-match a detected partner name to a stored thread on the same platform.
    func matchThread(name: String?, platform: Platform) -> UUID? {
        guard let name = name?.lowercased(), !name.isEmpty else { return nil }
        let threads = (try? store.threads()) ?? []
        // Prefer same-platform title/contact matches.
        for thread in threads where thread.platform == platform {
            if let title = thread.title?.lowercased(), title.contains(name) || name.contains(title) {
                return thread.id
            }
            let contacts = (try? store.contacts(inThread: thread.id)) ?? []
            if contacts.contains(where: { ($0.displayName?.lowercased().contains(name) ?? false) }) {
                return thread.id
            }
        }
        return nil
    }

    /// The send target for a thread (platform-native thread id, so backend send
    /// routes correctly; iMessage uses the handle).
    func sendTarget(threadID: UUID, platform: Platform) -> String {
        if platform == .imessage {
            let contacts = (try? store.contacts(inThread: threadID)) ?? []
            return contacts.first?.handle ?? ""
        }
        return (try? store.thread(id: threadID))?.platformThreadID ?? ""
    }
}
