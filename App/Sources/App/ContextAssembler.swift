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
        return SuggestionContext(
            relationshipLabel: project?.title ?? personName,
            platform: platform,
            goalText: project?.goalText,
            toneHint: toneOverride ?? project?.toneHint,
            boundaries: project?.boundaries ?? [],
            selfContext: project?.selfContext,
            relationshipMemory: memory?.promptContext,
            transcript: transcript,
            userIntent: userIntent)
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
