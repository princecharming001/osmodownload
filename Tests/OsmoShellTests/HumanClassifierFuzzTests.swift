import Testing
import Foundation
import OsmoCore
@testable import OsmoShell

/// Table-driven "fuzz corpus" over the human/automated classifier: realistic
/// mess — emoji-heavy friends, non-Latin names and bodies, empty strings, odd
/// handles, saved-contact OTPs, forwarded marketing — each with the expected
/// verdict AND the expected surfaced reason. One test, many rows, so a rule
/// tweak that flips any of these fails loudly with the case's label.
@Suite("Human classifier — fuzz corpus")
struct HumanClassifierFuzzTests {

    typealias Signals = HumanThreadClassifier.HumanSignals

    struct Case {
        let label: String
        let signals: Signals
        let human: Bool
        /// Expected `Verdict.reason` (nil for human verdicts).
        let reason: String?
        init(_ label: String, _ signals: Signals, human: Bool, reason: String? = nil) {
            self.label = label; self.signals = signals; self.human = human; self.reason = reason
        }
    }

    /// Signals builder with friend-shaped defaults.
    private static func sig(platform: Platform = .imessage, group: Bool = false,
                            handles: [String] = ["+15551234567"], names: [String] = ["Sam Rivera"],
                            resolved: Bool = false, replied: Bool = false,
                            texts: [String] = [], count: Int? = nil,
                            serverHint: Bool = false, llm: Bool? = nil,
                            subject: String? = nil, everMessaged: Bool = false) -> Signals {
        Signals(platform: platform, isGroup: group,
                counterpartyHandles: handles, counterpartyNames: names,
                hasResolvedPerson: resolved, userReplied: replied,
                inboundTexts: texts, inboundCount: count ?? texts.count,
                serverAutomatedHint: serverHint, llmSaysAutomated: llm,
                subjectOrTitle: subject, userEverMessagedSender: everMessaged)
    }

    static let corpus: [Case] = [
        // ---- Emoji-heavy friends -------------------------------------------------
        Case("emoji-heavy friend, replied",
             sig(replied: true, texts: ["🎉🎉🎉 WE GOT THE APARTMENT 🏠✨", "omg omg 😭😭"]),
             human: true),
        Case("emoji-heavy friend, not yet replied",
             sig(texts: ["🥺👉👈 u coming tonight??", "🍕🍕🍕"]),
             human: true),
        Case("emoji-only messages, replied",
             sig(replied: true, texts: ["👍", "😂😂😂", "❤️"]),
             human: true),

        // ---- Non-Latin names + bodies --------------------------------------------
        Case("Chinese name + Chinese body, replied",
             sig(names: ["王伟"], replied: true, texts: ["今晚一起吃饭吗？", "好久不见了"]),
             human: true),
        Case("Chinese name, one-way so far",
             sig(names: ["王伟"], texts: ["下周回北京"]),
             human: true),
        Case("Arabic name + Arabic body",
             sig(names: ["محمد الأحمد"], texts: ["كيف حالك يا صديقي؟"]),
             human: true),
        Case("Cyrillic full name, replied",
             sig(names: ["Иван Петров"], replied: true, texts: ["Привет! Как дела?"]),
             human: true),
        Case("ALL-CAPS Cyrillic single token stays human (brand nudge alone is not enough)",
             sig(names: ["ИВАН"], texts: ["привет"]),
             human: true),
        Case("Hebrew RTL body with marks, replied",
             sig(names: ["נועה לוי"], replied: true, texts: ["מה שלומך? 🙂"]),
             human: true),

        // ---- Empty / degenerate inputs -------------------------------------------
        Case("everything empty",
             Signals(platform: .imessage),
             human: true),
        Case("empty-string handle, name, and text",
             sig(handles: [""], names: [""], texts: [""]),
             human: true),
        Case("whitespace-only name and text",
             sig(names: ["   "], texts: ["   \n  "]),
             human: true),
        Case("emoji-only subject from a friend",
             sig(platform: .gmail, handles: ["ana.paz@gmail.com"], names: ["Ana Paz"],
                 texts: ["happy birthday!!"], subject: "🎉🎉🎉"),
             human: true),

        // ---- Odd handles -----------------------------------------------------------
        Case("handle 'unknown' with a resolved saved contact is a person",
             sig(handles: ["unknown"], names: ["Dele Adeyemi"], resolved: true,
                 texts: ["it's dele, new number"]),
             human: true),
        Case("handle 'unknown', unresolved and one-way, reads as a sender id",
             sig(handles: ["unknown"], names: [], texts: ["service notice"]),
             human: false, reason: "automated sender ID"),
        Case("weirdly formatted phone, replied",
             sig(handles: ["+1 (415) 555-2671"], replied: true, texts: ["lunch tmrw?"]),
             human: true),
        Case("dotted phone format, one-way first contact",
             sig(handles: ["415.555.2671"], names: ["Priya"], texts: ["hey it's priya from the gym"]),
             human: true),
        Case("G-72521 style verification sender id",
             sig(handles: ["G-72521"], names: [], texts: ["G-482193 is your Google verification code."]),
             human: false, reason: "verification code"),
        Case("5-digit shortcode with a neutral text",
             sig(handles: ["55512"], names: [], texts: ["Your table is ready."]),
             human: false, reason: "texted from a shortcode"),
        Case("short Slack username is NOT an A2P sender id",
             sig(platform: .slack, handles: ["jdoe"], names: ["J. Doe"], replied: true,
                 texts: ["can you review my PR?"]),
             human: true),

        // ---- Human names that look brandish ---------------------------------------
        Case("a person named Nike Adeyemi is a person",
             sig(names: ["Nike Adeyemi"], texts: ["are we still on for saturday?"]),
             human: true),
        Case("single-token NIKE + marketing blast is a brand",
             sig(names: ["NIKE"], texts: ["FLASH SALE 40% off everything, shop now!"]),
             human: false, reason: "marketing / notification"),
        Case("very long single-token name does not crash or flip",
             sig(names: [String(repeating: "Aa", count: 300)], texts: ["hi"]),
             human: true),

        // ---- Saved contact + OTP / forwarded marketing -----------------------------
        Case("OTP text in a resolved thread the user replies to stays human",
             sig(names: ["Chris Ono"], resolved: true, replied: true,
                 texts: ["my login code is 482913, can you read it off the ipad?"]),
             human: true),
        Case("OTP from a saved-but-never-answered sender is still an OTP",
             sig(names: ["Chase"], resolved: false,
                 texts: ["Your verification code is 284617. Do not share it."]),
             human: false, reason: "verification code"),
        Case("friend forwarding a 50%-off deal (replied + resolved) is rescued",
             sig(names: ["Maya Chen"], resolved: true, replied: true,
                 texts: ["check out this 50% off deal lol", "we should go"]),
             human: true),
        Case("marketing-looking text from someone you reply to (unresolved) stays visible",
             sig(names: ["Maya Chen"], replied: true,
                 texts: ["check out this 50% off deal lol"]),
             human: true),

        // ---- Email shapes -----------------------------------------------------------
        Case("noreply@ is never a person",
             sig(platform: .gmail, handles: ["noreply@stripe.com"], names: ["Stripe"]),
             human: false, reason: "automated sender"),
        Case("no.reply@ with dots collapses to the same hard rule",
             sig(platform: .gmail, handles: ["no.reply@foo.com"], names: ["Foo"]),
             human: false, reason: "automated sender"),
        Case("unicode localpart at a personal domain, first contact",
             sig(platform: .gmail, handles: ["josé.garcía@gmail.com"], names: ["José García"],
                 texts: ["great meeting you at the conference!"]),
             human: true),
        Case("brand with emoji subject via hello@",
             sig(platform: .gmail, handles: ["hello@glossier.com"], names: ["GLOSSIER"],
                 texts: ["New drops you'll love"], subject: "✨ you deserve this ✨"),
             human: false, reason: "service email address"),
        Case("newsletter through a bulk-mail subdomain",
             sig(platform: .gmail, handles: ["news@mail.exampleletter.com"], names: ["The Letter"],
                 texts: ["This week in tech..."]),
             human: false, reason: "service email address"),
        Case("templated subject + service sender",
             sig(platform: .gmail, handles: ["orders@shop.example.com"], names: ["Shop"],
                 texts: ["Track your package here"], subject: "Your order has shipped"),
             human: false, reason: "service email address"),
        Case("recruiter writing first from a work address stays visible",
             sig(platform: .gmail, handles: ["jordan.lee@acme-corp.com"], names: ["Jordan Lee"],
                 texts: ["Saw your work on the sync engine — impressive."]),
             human: true),

        // ---- Groups ------------------------------------------------------------------
        Case("group chat with mixed human + bot members is human",
             sig(group: true, handles: ["+15551230001", "22000"], names: ["Ana García", "AMZN"],
                 texts: ["who's driving?", "AMZN: your package arrived"]),
             human: true),
        Case("group of only shortcode senders with OTP content is hidden",
             sig(group: true, handles: ["262966", "22000"], names: ["AMZN", "FEDEX"],
                 texts: ["Your one-time passcode is 993412"]),
             human: false, reason: "verification code"),

        // ---- Long / hostile inputs ----------------------------------------------------
        Case("10k-char friendly wall of text, replied",
             sig(replied: true, texts: [String(repeating: "so then we drove to tahoe and ", count: 350)]),
             human: true),
        Case("marketing phrase early in a 10k-char blob still caught",
             sig(names: ["DEALS"], texts: ["Unsubscribe anytime. " + String(repeating: "buy buy buy ", count: 900)]),
             human: false, reason: "marketing / notification"),
        Case("1MB single message neither crashes nor flips a friend",
             sig(replied: true, texts: [String(repeating: "a", count: 1_000_000)]),
             human: true),
        Case("cold pitch language buried past the scan cap does not count",
             // The pitch phrases sit beyond maxScannedChars — bounded scanning
             // means bounded evidence, and that's the accepted trade.
             sig(names: ["Alex Sales"], texts: [String(repeating: "z", count: 3000)
                 + " book a demo we help companies grow your pipeline"]),
             human: true),
        Case("cold pitch inside the scan window is still caught",
             sig(names: ["Alex Sales"], texts: ["I'll keep this brief — we help companies like yours. Book a demo?"]),
             human: false, reason: "cold outreach"),
        Case("subject that is 10k chars of padding after a templated opener",
             sig(platform: .gmail, handles: ["billing@example.com"], names: ["Example"],
                 texts: ["Your invoice is attached"],
                 subject: "Your invoice is ready " + String(repeating: "x", count: 10_000)),
             human: false, reason: "service email address"),
    ]

    @Test("every corpus row gets the expected verdict and reason")
    func corpusVerdicts() {
        for c in Self.corpus {
            let v = HumanThreadClassifier.classify(c.signals)
            #expect(v.isLikelyHuman == c.human, "case: \(c.label) — got \(v)")
            if let expected = c.reason {
                #expect(v.reason == expected, "case: \(c.label) — got reason \(v.reason ?? "nil")")
            } else if c.human {
                #expect(v.reason == nil, "case: \(c.label) — human verdicts carry no reason")
            }
        }
    }

    @Test("reciprocity hard-override survives the tuning: replied on a normal handle, clean thread")
    func reciprocityStillWins() {
        // The contract other suites rely on — spelled out here too so a future
        // corpus tweak can't quietly weaken it.
        let v = HumanThreadClassifier.classify(
            Self.sig(replied: true, texts: ["ok see you at 8"], serverHint: true))
        #expect(v.isLikelyHuman)
        #expect(v.score == 0)
    }

    @Test("classification of a pathological thread is bounded (caps in force)")
    func boundedWork() {
        // 50 sampled texts of 1MB each — the caps must keep this instant.
        let texts = Array(repeating: String(repeating: "m", count: 1_000_000), count: 50)
        let signals = Self.sig(texts: texts)
        let clock = ContinuousClock()
        let elapsed = clock.measure { _ = HumanThreadClassifier.classify(signals) }
        #expect(elapsed < .seconds(2), "classify took \(elapsed)")
    }
}
