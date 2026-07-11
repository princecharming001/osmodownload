import Foundation
import OsmoCore

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

        METHOD LIBRARY (apply ONLY the moves named in THE MOVE below; here is how each is actually done):
        - Tactical empathy (Voss): LABEL a likely feeling with "it sounds like…/it seems like…"; MIRROR by echoing their last 1–3 words; ask CALIBRATED "how/what" questions, never yes/no pressure; run an ACCUSATION AUDIT — name the worst thing they might be thinking, first, so it loses its charge.
        - Repair & bids (Gottman): a CLEAN apology owns the specific thing with no "but"/"if", names the impact on them, offers one concrete repair, and says sorry once. SOFT START-UP: speak from "I", one issue, no character attack. TURN TOWARD THE BID: answer the feeling under the words, not just the literal content.
        - NVC (Rosenberg): for a hard raise, structure observation (a fact, no evaluation) → feeling → need → one concrete, doable request. No blame, no "you always/never".
        - Attachment: when they've gone quiet, do NOT do protest behavior (double-texting, out-warming them, testing, guilt). Offer secure, low-pressure warmth with an easy way back in. When momentum is clearly mutual, it's safe to escalate.
        - Influence (Cialdini): lead with genuine value before any ask (reciprocity); tie the ask to something they already said or value (consistency); make the ask the smallest next step (an easy yes). Never fabricate scarcity, deadlines, or social proof.
        - Linguistic Style Matching: converge to their length, casing, punctuation, and energy so the message fits the thread. Matching signals rapport; over-completeness and over-formality signal distance.

        You apply all of this as empathy — helping the user be understood and move a relationship where they want it — never to manipulate, pressure, guilt, or deceive. If a request asks you to exploit or coerce someone, refuse and say why.

        Every draft is something the user will read, maybe edit, and choose to send. It must feel like it came out of their own thumbs — texting norms, not email prose: short, human, unpolished where they'd be unpolished.

        \(AntiTell.block)

        HOW YOU RESPOND
        Return exactly three takes of the message, one per line, in this order:
        1) the direct version — says the thing cleanly
        2) the warmer version — same thing, more warmth/relationship
        3) the lighter version — same thing, more play/ease
        No labels, no numbering, no quotation marks, no commentary. Just three lines.
        """
    }()

    /// `now` MUST be the same instant handed to `ThreadRead.read` (OsmoBrain.plan
    /// guarantees this) — otherwise the idle math and the moment lines disagree.
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
                               read: ThreadRead,
                               now: Date = Date(),
                               partnerBackground: String? = nil) -> ComposedPrompt {
        var s: [String] = []

        s.append("WHO YOU'RE TEXTING")
        s.append("They are your \(relationshipLabel).")
        if let bg = partnerBackground, !bg.isEmpty {
            s.append("WHO THEY ARE: \(bg)")
        }
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

        // One read of the other person feeds both the timing section and the
        // per-person style directives below.
        let partner = PartnerProfile.read(transcript)

        // Read the room: who owes and whether the user is over-carrying — the
        // difference between a natural reply and a needy one. (All clock-shaped
        // silence interpretation lives in `timing` — single owner, no contradictions.)
        let state = threadState(read)
        if !state.isEmpty {
            s.append("\nREAD OF WHERE THIS STANDS")
            for line in state { s.append("- \(line)") }
        }

        // WHEN this lands: their reply rhythm vs the current silence, their
        // active hours vs right now, and odd-hour cautions — the "knows when,
        // not just what" half of the product.
        let when = timing(read: read, partner: partner, transcript: transcript, now: now)
        if !when.isEmpty {
            s.append("\nWHEN THIS LANDS")
            for line in when { s.append("- \(line)") }
        }

        // How the USER themselves texts — the draft must sound like them.
        let voice = VoiceProfile.read(transcript)
        if !voice.isEmpty {
            s.append("\nYOUR OWN TEXTING VOICE (sound like this)")
            for line in voice { s.append("- \(line)") }
        }

        // How THIS PERSON communicates, read from their whole history — the
        // durable per-person register (the last-message calibration below handles
        // the immediate moment; this handles who they are).
        if !partner.directives.isEmpty {
            s.append("\nHOW THEY COMMUNICATE (calibrate to this person)")
            for line in partner.directives { s.append("- \(line)") }
        }

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
        turns.suffix(20).map { ($0.fromMe ? "You: " : "\(($0.senderName ?? "Them")): ") + $0.text }
            .joined(separator: "\n")
    }

    /// Relational state directives — attachment psychology only. ALL clock-shaped
    /// silence interpretation lives in `timing` (single owner, so the two sections
    /// can never contradict each other about the same quiet).
    static func threadState(_ read: ThreadRead) -> [String] {
        var lines: [String] = []
        if read.userCarrying {
            lines.append("You already sent the last message(s) and they've gone quiet. Do NOT double-text harder, over-warm, guilt, or test them. Keep it light and low-pressure, and give them an easy way back in.")
        }
        return lines
    }

    /// The timing read — WHEN people send messages, folded into the drafting
    /// logic. Owns every clock-shaped judgment: the current silence measured
    /// against THEIR reply rhythm (not a fixed threshold), what tempo to expect
    /// from them, whether this moment is inside their active window, and odd-hour
    /// wording cautions. Every line is gated so it only fires when honest.
    static func timing(read: ThreadRead, partner: PartnerProfile,
                       transcript: [ThreadTurn], now: Date) -> [String] {
        var lines: [String] = []
        // True once a silence line has framed their rhythm — the tempo line then
        // stays quiet instead of citing the same median twice.
        var framedRhythm = false

        // 1. Silence. Rhythm-aware ONLY when the quiet is theirs to break (the
        //    user sent last — ball == .mine); when THEY sent last, the silence is
        //    the user's, and claiming "they've gone quiet" would be false.
        if read.ball != .empty, let idle = read.idle, idle > 0 {
            let days = Int(idle / 86_400)
            let median = read.ball == .mine ? partner.medianReplySeconds : nil
            if idle >= 7 * 86_400 {
                // Past a week, ratios stop meaning anything — days phrasing.
                lines.append("This thread's been quiet ~\(days) days — acknowledge the gap lightly and honestly; don't pretend no time passed or over-apologize for it.")
            } else if let median, median > 0 {
                let ratio = idle / median
                let gap = PartnerProfile.humanGap(median)
                if ratio >= 3, idle >= 86_400 {
                    // The absolute floor keeps a fast replier's 3-hour nap from
                    // reading as abandonment (ratio alone would scream 36x).
                    framedRhythm = true
                    if ratio >= 10 {
                        lines.append("They've been quiet far past their usual reply rhythm (typically ~\(gap)) — a light, no-pressure re-open is warranted.")
                    } else {
                        lines.append("They've been quiet ~\(Int(ratio.rounded()))x longer than their usual reply rhythm (typically ~\(gap)) — a light, no-pressure re-open is warranted.")
                    }
                } else if idle >= 2 * 86_400 {
                    framedRhythm = true
                    if ratio < 1.5 {
                        lines.append("It's been ~\(days) days, but that's within their normal rhythm (they typically take ~\(gap)) — don't read into it or write like there's a gap to acknowledge.")
                    } else {
                        lines.append("A bit longer than their usual rhythm — a light re-entry works; don't make the gap a thing.")
                    }
                }
                // else: no silence line at all — under the floors, quiet is noise.
            } else if idle >= 2 * 86_400 {
                // No rhythm data (or the quiet is the user's own): the honest
                // sender-agnostic fallback, unchanged from before.
                lines.append("It's been a couple days — a light re-entry beats acting like it's mid-conversation.")
            }
        }

        // 2. Reply-tempo expectation — only for genuinely slow repliers, and only
        //    when the silence lines didn't already frame their rhythm.
        if !framedRhythm, let median = partner.medianReplySeconds, median >= 1800 {
            lines.append("They typically reply in ~\(PartnerProfile.humanGap(median)) — don't write anything that begs a faster answer.")
        }

        // 3. Their active window vs right now — reply expectation only (the
        //    moment line below owns time-reference wording).
        if let block = partner.activeBlock {
            let nowBlock = PartnerProfile.hourBlock(Calendar.current.component(.hour, from: now))
            if nowBlock == block {
                lines.append("This lands in their usual active window (\(block)) — natural timing.")
            } else {
                lines.append("They're usually active \(block); it's \(nowBlock) now — don't expect a fast reply, and don't write anything that presumes one.")
            }
        }

        // 4. The current moment — wording cautions for odd hours.
        let hour = Calendar.current.component(.hour, from: now)
        if hour >= 23 || hour < 5 {
            lines.append("It's the middle of the night — don't propose plans for 'tonight' or 'today' ambiguously; if the odd hour is noticeable, acknowledging it naturally is fine.")
        } else if hour < 7 {
            lines.append("It's very early in the morning — don't write as if their day is already underway.")
        }

        // 5. THEIR last message's send hour — energy context, only while fresh.
        if read.ball == .theirs, let idle = read.idle, idle < 8 * 3600,
           let lastTheirs = transcript.last(where: { !$0.fromMe })?.sentAt {
            let h = Calendar.current.component(.hour, from: lastTheirs)
            if h >= 23 || h < 5 {
                lines.append("Their last message was sent late at night — read the energy as end-of-day, not peak.")
            }
        }

        return lines
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
