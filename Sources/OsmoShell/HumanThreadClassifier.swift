import Foundation
import OsmoCore

/// Pure, deterministic classifier that decides whether a thread is a **genuine
/// conversation with a person** vs. something automated — an OTP/verification
/// bot, a marketing blast, a no-reply notification, a shortcode, an A2P sender.
///
/// The app assembles `HumanSignals` from already-fetched store rows (handles,
/// names, a bounded message sample) and this decides. No I/O, so it's fully
/// unit-tested and the same call powers the inbox/people/today "people only"
/// default.
///
/// Design: a small integer accumulator of *non-human evidence*, plus a couple of
/// unambiguous hard overrides at each end. A thread is non-human once the score
/// reaches `threshold`. The overrides carry the real weight — reciprocity (you
/// actually replied on a normal handle) is decisive for human; a no-reply email
/// localpart is decisive for machine. This keeps real people who happen to text
/// from odd numbers, and businesses you genuinely go back-and-forth with, on the
/// human side, while catching the codes and blasts.
public enum HumanThreadClassifier {
    public static let threshold = 3

    /// Everything the classifier needs, pulled from the store by the app. Kept a
    /// plain value so tests construct it directly (no DB, no models required).
    public struct HumanSignals: Sendable {
        public var platform: Platform
        public var isGroup: Bool
        /// Raw handles of the OTHER party (the user's own contact excluded).
        public var counterpartyHandles: [String]
        /// Non-empty display names of the other party.
        public var counterpartyNames: [String]
        /// Any counterparty contact already resolved to a merged Person.
        public var hasResolvedPerson: Bool
        /// The user has sent at least one message in this thread.
        public var userReplied: Bool
        /// A bounded sample of inbound (not-from-me) message texts.
        public var inboundTexts: [String]
        /// Number of inbound messages in the sample.
        public var inboundCount: Int
        /// Server-side signal (Gmail List-Unsubscribe/Precedence/sender-shape,
        /// `WireThread.automatedHint`) — a bulk/automated sender, independent of
        /// what any single message's text looks like.
        public var serverAutomatedHint: Bool
        /// The LLM's own read on this thread (ThreadIntel's AUTOMATED line) — it
        /// sees the full recent transcript, so it catches shapes (a service-y
        /// sender with a bland first message) the regexes below miss.
        public var llmSaysAutomated: Bool?

        public init(platform: Platform, isGroup: Bool = false,
                    counterpartyHandles: [String] = [], counterpartyNames: [String] = [],
                    hasResolvedPerson: Bool = false, userReplied: Bool = false,
                    inboundTexts: [String] = [], inboundCount: Int = 0,
                    serverAutomatedHint: Bool = false, llmSaysAutomated: Bool? = nil) {
            self.platform = platform
            self.isGroup = isGroup
            self.counterpartyHandles = counterpartyHandles
            self.counterpartyNames = counterpartyNames
            self.hasResolvedPerson = hasResolvedPerson
            self.userReplied = userReplied
            self.inboundTexts = inboundTexts
            self.inboundCount = inboundCount
            self.serverAutomatedHint = serverAutomatedHint
            self.llmSaysAutomated = llmSaysAutomated
        }
    }

    public struct Verdict: Equatable, Sendable {
        public var isLikelyHuman: Bool
        /// A short machine reason when non-human (for the "why hidden" affordance).
        public var reason: String?
        public var score: Int
    }

    public static func classify(_ s: HumanSignals) -> Verdict {
        let texts = s.inboundTexts.map { $0.lowercased() }
        let anyOTP = texts.contains(where: looksLikeOTP)
        let anyMarketing = texts.contains(where: looksLikeMarketing)
        let handles = s.counterpartyHandles

        // ---- Hard NON-human: a no-reply/automated email localpart is, by
        // definition, not a person. Nothing overrides this.
        if handles.contains(where: isAutomatedEmail) {
            return Verdict(isLikelyHuman: false, reason: "automated sender", score: 99)
        }

        let allShortcodeOrSender = !handles.isEmpty && handles.allSatisfy {
            isShortcode($0) || isAlphaSender($0, platform: s.platform)
        }

        // ---- Hard HUMAN overrides.
        // A group chat with actually-named people is a human conversation.
        if s.isGroup && s.counterpartyNames.contains(where: looksHumanName) {
            return Verdict(isLikelyHuman: true, reason: nil, score: 0)
        }
        // Reciprocity: you replied, on a normal handle (not a shortcode / A2P
        // sender id), with no OTP/marketing in the thread — people don't chat
        // back and forth with bots. Rescues a real person on an unusual number
        // and a business you genuinely converse with.
        if s.userReplied && !allShortcodeOrSender && !anyOTP && !anyMarketing {
            return Verdict(isLikelyHuman: true, reason: nil, score: 0)
        }
        // A resolved, humanly-named person you've engaged.
        if s.hasResolvedPerson && s.userReplied && s.counterpartyNames.contains(where: looksHumanName) {
            return Verdict(isLikelyHuman: true, reason: nil, score: 0)
        }

        // ---- Additive non-human evidence.
        var score = 0
        var reason: String?
        func add(_ n: Int, _ why: String) { score += n; if reason == nil { reason = why } }

        if !handles.isEmpty && handles.allSatisfy(isShortcode) { add(2, "texted from a shortcode") }
        if handles.contains(where: { isAlphaSender($0, platform: s.platform) }) {
            add(2, "automated sender ID")
        }
        if anyOTP { add(3, "verification code") }
        if anyMarketing { add(2, "marketing / notification") }
        // Server- and model-read automated evidence — each alone clears the
        // threshold. Deliberately AFTER the hard-human overrides above: a
        // thread the user has actually replied to on a normal handle stays
        // human even if a bulk header slipped in (e.g. a business newsletter
        // you also get real replies from), matching the reciprocity contract.
        if s.serverAutomatedHint { add(3, "newsletter / bulk sender") }
        if s.llmSaysAutomated == true { add(3, "AI: automated sender") }
        // One-directional: they message, you never reply — a broadcast pattern.
        if !s.userReplied && s.inboundCount >= 1 { add(1, "one-way messages") }
        // A single brand-shaped name token (all caps or with digits) is a weak nudge.
        if s.counterpartyNames.allSatisfy(looksBrandName), !s.counterpartyNames.isEmpty {
            add(1, "brand-like name")
        }

        // Cold outreach / sales pitch — the LinkedIn slip-through class. A REAL
        // human, but not a conversation: templated pitch language at someone who
        // never replied. Any reply from the user rescues it (the hard-human
        // override above), so a salesperson you actually talk to stays visible.
        if !s.userReplied {
            let pitchHits = texts.reduce(0) { $0 + salesPitchHits($1) }
            if pitchHits >= 2 {
                return Verdict(isLikelyHuman: false, reason: "cold outreach", score: 99)
            }
            if pitchHits == 1 { add(2, "cold outreach") }
            // The cold-pitch shape: opens with a monologue (long first messages).
            let avgWords = texts.isEmpty ? 0
                : texts.map { $0.split(separator: " ").count }.reduce(0, +) / texts.count
            if avgWords > 45 { add(2, "unsolicited monologue") }
            // Links you never asked for.
            if texts.contains(where: { $0.contains("http") || $0.contains("calendly") }) {
                add(1, "unsolicited links")
            }
        }

        if score >= threshold {
            return Verdict(isLikelyHuman: false, reason: reason ?? "looks automated", score: score)
        }
        return Verdict(isLikelyHuman: true, reason: nil, score: score)
    }

    // MARK: - Handle shapes

    /// A shortcode: a numeric SMS code (e.g. 262966, 22000) — the normalizer files
    /// these as username-kind (fewer than 7 digits), all-digit, length 3–6.
    static func isShortcode(_ handle: String) -> Bool {
        let norm = HandleNormalizer.normalize(handle)
        guard norm.kind == .username else { return false }
        let v = norm.value
        return v.count >= 3 && v.count <= 6 && v.allSatisfy(\.isNumber)
    }

    /// An A2P alphanumeric sender ID (VERIFY, GITHUB, AMZN, G-72521): letters
    /// present, short, no spaces, not an email — and only meaningful on SMS/
    /// iMessage, where real correspondents use phone numbers. On Slack/Instagram
    /// a short username is normal, so we don't apply it there.
    static func isAlphaSender(_ handle: String, platform: Platform) -> Bool {
        guard platform == .imessage else { return false }
        let t = handle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.contains("@"), !t.contains(" "), t.count <= 11 else { return false }
        let norm = HandleNormalizer.normalize(handle)
        guard norm.kind == .username else { return false }         // not a real phone
        return t.contains(where: \.isLetter)                        // has letters ⇒ sender id
    }

    /// Automated email localparts that never belong to a person.
    static func isAutomatedEmail(_ handle: String) -> Bool {
        let norm = HandleNormalizer.normalize(handle)
        guard norm.kind == .email else { return false }
        let local = norm.value.split(separator: "@").first.map(String.init) ?? norm.value
        let collapsed = local.replacingOccurrences(of: ".", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
        let exact: Set<String> = [
            "noreply", "no-reply", "donotreply", "do-not-reply", "notifications",
            "notification", "notify", "mailer", "mailerdaemon", "postmaster",
            "bounce", "bounces", "newsletter", "newsletters", "updates", "alerts",
            "automated", "system", "robot", "bot", "mail", "email",
        ]
        if exact.contains(collapsed) { return true }
        for prefix in ["noreply", "donotreply", "noreply", "mailerdaemon"] {
            if collapsed.hasPrefix(prefix) { return true }
        }
        return false
    }

    // MARK: - Text shapes

    static func looksLikeOTP(_ lower: String) -> Bool {
        let phrases = ["verification code", "one-time", "one time pass", "your otp",
                       "otp is", "2fa", "two-factor", "two factor", "security code",
                       "login code", "your code is", "code is", "authentication code",
                       "confirmation code", "passcode", "do not share", "verify your",
                       "is your amazon", "is your uber", "is your"]
        if phrases.contains(where: { lower.contains($0) }) { return true }
        // A standalone 4–8 digit number near a "code/verify" word.
        if (lower.contains("code") || lower.contains("verif") || lower.contains("otp")),
           containsDigitRun(lower, 4...8) { return true }
        return false
    }

    /// Count of templated sales/outreach phrases in one (lowercased) message.
    static func salesPitchHits(_ lower: String) -> Int {
        // Templated-outreach phrases only — nothing a friend would plausibly text
        // ("quick question" and "15 minutes" were cut for exactly that reason).
        let phrases = ["if your team", "book a demo", "book a call", "schedule a call",
                       "calendly.com", "i'll keep this brief",
                       "i'll keep it short", "reaching out because", "we help companies",
                       "we help businesses", "does this resonate", "worth a chat",
                       "no worries if not interested", "our platform", "grow your",
                       "sponsorship opportunity", "collab opportunity", "partnership opportunity",
                       "open to connecting", "pick your brain", "love to connect",
                       "hope this message finds you", "came across your profile"]
        return phrases.reduce(0) { $0 + (lower.contains($1) ? 1 : 0) }
    }

    static func looksLikeMarketing(_ lower: String) -> Bool {
        let phrases = ["unsubscribe", "reply stop", "txt stop", "text stop",
                       "stop to opt", "opt out", "opt-out", "view in browser",
                       "click here", "% off", "msg&data", "msg & data", "std msg",
                       "do not reply", "this is an automated", "shop now",
                       "limited time", "flash sale", "sale ends", "promo code"]
        return phrases.contains(where: { lower.contains($0) })
    }

    /// True if `s` contains a run of digits whose length falls in `range`.
    static func containsDigitRun(_ s: String, _ range: ClosedRange<Int>) -> Bool {
        var run = 0
        for ch in s {
            if ch.isNumber { run += 1; if range.contains(run) && run == range.upperBound { return true } }
            else { if range.contains(run) { return true }; run = 0 }
        }
        return range.contains(run)
    }

    // MARK: - Name shapes

    /// A human-looking display name: has a letter and either a space (first/last)
    /// or a normal capitalized token that isn't a shouty brand.
    static func looksHumanName(_ name: String) -> Bool {
        let t = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.contains(where: \.isLetter) else { return false }
        if t.contains(" ") { return true }
        return !looksBrandName(t)
    }

    /// A brand-shaped single token: ALL CAPS, or containing digits/symbols.
    static func looksBrandName(_ name: String) -> Bool {
        let t = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return false }
        if t.contains(where: \.isNumber) { return true }
        let letters = t.filter(\.isLetter)
        if letters.count >= 2, letters == letters.uppercased(), letters != letters.lowercased() {
            return true   // all-caps word like "AMZN", "VERIFY"
        }
        return false
    }
}
