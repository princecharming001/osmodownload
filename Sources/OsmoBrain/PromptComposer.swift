import Foundation

/// A composed prompt split into a **stable, cacheable core** (the role + method +
/// anti-tell ruleset — byte-identical across every request, so it's sent as a
/// prompt-cached system block for ~90% cheaper reads) and a **volatile user turn**
/// (this relationship, goal, thread, and selected techniques).
public struct ComposedPrompt: Equatable, Sendable {
    public var systemCore: String
    public var userTurn: String
}

public enum PromptComposer {
    /// The stable psychology core. Never interpolate per-request data here or the
    /// cache breaks. Kept large and specific on purpose — it's cached.
    public static let systemCore: String = {
        """
        You draft real text messages on behalf of the user, in the user's own voice, to one specific person. You are a ghostwriter who sounds exactly like them — never an assistant, never yourself. You keep their meaning and add nothing they wouldn't say.

        Your craft is grounded in communication psychology — tactical empathy and calibrated questions (negotiation), soft start-ups, repair attempts and turning toward bids (relationships), reciprocity and consistency (influence), and linguistic style matching. You apply these as empathy — helping the user be understood and move a relationship where they want it — never to manipulate, pressure, or deceive. If a request asks you to exploit or coerce someone, refuse and say why.

        Every draft you write is something the user will read, maybe edit, and choose to send. It must feel like it came out of their own thumbs.

        \(AntiTell.block)

        HOW YOU RESPOND
        Return exactly three takes of the message, one per line, in this order:
        1) the direct version — says the thing cleanly
        2) the warmer version — same thing, more warmth/relationship
        3) the lighter version — same thing, more play/ease
        No labels, no numbering, no quotation marks, no commentary. Just three lines.
        """
    }()

    public static func compose(relationshipLabel: String,
                               goalText: String?,
                               goalKind: GoalKind,
                               toneHint: String?,
                               boundaries: [String],
                               selfContext: String?,
                               relationshipMemory: String?,
                               transcript: [ThreadTurn],
                               userIntent: String?,
                               strategy: StrategyPlan,
                               read: ThreadRead) -> ComposedPrompt {
        var s: [String] = []

        s.append("WHO YOU'RE TEXTING")
        s.append("They are your \(relationshipLabel).")
        s.append(strategy.register.guidance)

        if let goalText, !goalText.trimmingCharacters(in: .whitespaces).isEmpty {
            s.append("\nYOUR GOAL WITH THEM")
            s.append("\(goalText) (\(goalKind.label)). Every message should move a step toward this — never at the cost of the relationship.")
        }
        if let toneHint, !toneHint.isEmpty { s.append("Tone to hold: \(toneHint).") }
        let realBounds = boundaries.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        if !realBounds.isEmpty { s.append("Never: \(realBounds.joined(separator: "; ")).") }
        if let selfContext, !selfContext.isEmpty { s.append("About you (the sender): \(selfContext).") }
        if let mem = relationshipMemory, !mem.isEmpty { s.append("\nWHAT YOU KNOW ABOUT THEM\n\(mem)") }

        if !transcript.isEmpty {
            s.append("\nTHE CONVERSATION SO FAR")
            s.append(render(transcript))
        }
        if let intent = userIntent, !intent.trimmingCharacters(in: .whitespaces).isEmpty {
            s.append("\nWHAT YOU WANT TO SAY\n\(intent)")
        }

        s.append("\nTHE MOVE (this message is \(movePhrase(strategy.move)))")
        for tech in strategy.techniques { s.append("- \(tech.directive)") }

        let cal = calibration(read)
        if !cal.isEmpty {
            s.append("\nMATCH THEIR MESSAGE")
            for line in cal { s.append("- \(line)") }
        }

        s.append("\nNow write the three takes.")
        return ComposedPrompt(systemCore: systemCore, userTurn: s.joined(separator: "\n"))
    }

    static func movePhrase(_ move: Move) -> String {
        switch move {
        case .apologize: return "an apology"
        case .decline: return "saying no"
        case .comfort: return "comforting them"
        case .deliverHardNews: return "delivering hard news"
        case .flirt: return "flirting"
        case .nudge: return "a follow-up nudge"
        case .celebrate: return "celebrating them"
        case .thank: return "saying thanks"
        case .checkIn: return "a check-in"
        case .ask: return "an ask"
        case .negotiate: return "a negotiation move"
        case .deescalate: return "cooling things down"
        case .persuade: return "making the case"
        case .scheduleTime: return "locking in a time"
        case .answer: return "answering them"
        case .smallTalk: return "light conversation"
        case .plain: return "a message"
        }
    }

    static func render(_ turns: [ThreadTurn]) -> String {
        turns.suffix(20).map { ($0.fromMe ? "You: " : "Them: ") + $0.text }
            .joined(separator: "\n")
    }

    /// Linguistic-Style-Matching instructions from the real thread read.
    static func calibration(_ read: ThreadRead) -> [String] {
        guard read.theirLastText != nil else { return [] }
        var lines: [String] = []
        if read.hasOpenQuestion { lines.append("They asked something — answer it in the first line.") }
        if read.wordCount <= 4 {
            lines.append("Their message is a few words — reply in ONE short line.")
        } else if read.wordCount <= 18 {
            lines.append("Their message is short — match it: one or two short sentences.")
        } else {
            lines.append("Their message is long — you can go fuller, but stay at or under their length.")
        }
        if read.mostlyLowercase { lines.append("They text in lowercase — mirror it.") }
        lines.append(read.usesEmoji ? "They use emoji — one is fine if it's natural."
                                     : "No emoji — they didn't use any.")
        if read.exclaims { lines.append("Their energy is up — you can match it (one exclamation max).") }
        if read.sentiment < -0.2 { lines.append("Their tone is down — lead with warmth, don't be chirpy.") }
        return lines
    }
}
