import Testing
import Foundation
@testable import OsmoShell
import OsmoCore

@Suite("Human vs. automated conversation filter")
struct HumanThreadClassifierTests {
    typealias S = HumanThreadClassifier.HumanSignals

    private func classify(_ s: S) -> HumanThreadClassifier.Verdict {
        HumanThreadClassifier.classify(s)
    }

    // MARK: - Non-human catches

    @Test("OTP / verification codes are hidden")
    func otp() {
        let v = classify(S(platform: .imessage, counterpartyHandles: ["262966"],
                           counterpartyNames: ["VERIFY"], userReplied: false,
                           inboundTexts: ["Your verification code is 483920. Do not share it."],
                           inboundCount: 1))
        #expect(!v.isLikelyHuman)
    }

    @Test("A no-reply email is never a person")
    func noReply() {
        let v = classify(S(platform: .gmail, counterpartyHandles: ["noreply@github.com"],
                           counterpartyNames: ["GitHub"], userReplied: false,
                           inboundTexts: ["A new sign-in to your account"], inboundCount: 1))
        #expect(!v.isLikelyHuman)
        #expect(v.reason == "automated sender")
    }

    @Test("notifications@ / mailer-daemon localparts are automated")
    func automatedLocalparts() {
        for h in ["notifications@instagram.com", "mailer-daemon@mail.com",
                  "no-reply@stripe.com", "newsletter@substack.com"] {
            #expect(!classify(S(platform: .gmail, counterpartyHandles: [h])).isLikelyHuman)
        }
    }

    @Test("Marketing blast with unsubscribe / STOP is hidden")
    func marketing() {
        let v = classify(S(platform: .imessage, counterpartyHandles: ["AMZN"],
                           counterpartyNames: ["AMZN"], userReplied: false,
                           inboundTexts: ["Flash sale! 50% off today only. Reply STOP to opt out."],
                           inboundCount: 1))
        #expect(!v.isLikelyHuman)
    }

    @Test("Alphanumeric A2P sender id on iMessage is automated")
    func alphaSender() {
        let v = classify(S(platform: .imessage, counterpartyHandles: ["GITHUB"],
                           counterpartyNames: ["GITHUB"], userReplied: false,
                           inboundTexts: ["Sign-in requested"], inboundCount: 1))
        #expect(!v.isLikelyHuman)
    }

    @Test("Shortcode + one-way is hidden")
    func shortcodeOneWay() {
        let v = classify(S(platform: .imessage, counterpartyHandles: ["22395"],
                           userReplied: false,
                           inboundTexts: ["Your ride is arriving", "Trip receipt"], inboundCount: 2))
        #expect(!v.isLikelyHuman)   // shortcode +2, one-way +1 → 3
    }

    // MARK: - Human rescues (false-positive guards)

    @Test("A real friend on a normal number you text back is human")
    func realFriend() {
        let v = classify(S(platform: .imessage, counterpartyHandles: ["+15551234567"],
                           counterpartyNames: ["Sarah Chen"], hasResolvedPerson: true,
                           userReplied: true,
                           inboundTexts: ["you around this weekend?", "wanna grab dinner"],
                           inboundCount: 2))
        #expect(v.isLikelyHuman)
    }

    @Test("A real person on a short/unusual number you replied to is rescued by reciprocity")
    func realPersonShortNumber() {
        // Even though the handle is odd, you replied and there's no OTP/marketing.
        let v = classify(S(platform: .imessage, counterpartyHandles: ["4432"],
                           counterpartyNames: ["Mom"], userReplied: true,
                           inboundTexts: ["call me when you get a sec"], inboundCount: 1))
        #expect(v.isLikelyHuman)
    }

    @Test("A business you genuinely go back and forth with stays visible")
    func twoWayBusiness() {
        let v = classify(S(platform: .imessage, counterpartyHandles: ["+18005551212"],
                           counterpartyNames: ["Bella Salon"], userReplied: true,
                           inboundTexts: ["Can we move you to 3pm?", "Great, see you then!"],
                           inboundCount: 2))
        #expect(v.isLikelyHuman)   // reciprocity, no OTP/marketing
    }

    @Test("A group chat with named people is human")
    func groupChat() {
        let v = classify(S(platform: .whatsapp, isGroup: true,
                           counterpartyHandles: ["5551110000", "5552220000"],
                           counterpartyNames: ["Alex Rivera", "Jordan Lee"],
                           userReplied: false,
                           inboundTexts: ["who's in for saturday"], inboundCount: 1))
        #expect(v.isLikelyHuman)
    }

    @Test("Someone who just texted you (not replied yet) on a real number is still human")
    func newInboundRealPerson() {
        let v = classify(S(platform: .imessage, counterpartyHandles: ["+14155559876"],
                           counterpartyNames: ["Chris Park"], hasResolvedPerson: true,
                           userReplied: false,
                           inboundTexts: ["hey it's chris from the gym"], inboundCount: 1))
        #expect(v.isLikelyHuman)   // one-way +1 only, well under threshold
    }

    @Test("Slack short usernames are NOT treated as A2P senders")
    func slackUsernameOK() {
        let v = classify(S(platform: .slack, counterpartyHandles: ["U8842"],
                           counterpartyNames: ["Dana"], userReplied: true,
                           inboundTexts: ["ship it?"], inboundCount: 1))
        #expect(v.isLikelyHuman)
    }
}

@Suite("Cold-outreach hardening — the LinkedIn slip-through class")
struct ColdOutreachTests {
    typealias S = HumanThreadClassifier.HumanSignals

    @Test("A templated LinkedIn sales pitch you never answered is hidden")
    func linkedinPitch() {
        let v = HumanThreadClassifier.classify(S(
            platform: .linkedin, counterpartyHandles: ["urn:li:member:99"],
            counterpartyNames: ["Jordan Sales"], userReplied: false,
            inboundTexts: ["Hey Anish, if your team is maintaining a data pipeline, we help companies cut costs — worth a chat? calendly.com/jordan"],
            inboundCount: 1))
        #expect(!v.isLikelyHuman)
        #expect(v.reason == "cold outreach")
    }

    @Test("An unsolicited monologue with a link scores toward hidden")
    func monologue() {
        let long = Array(repeating: "word", count: 60).joined(separator: " ") + " http://pitch.example"
        let v = HumanThreadClassifier.classify(S(
            platform: .linkedin, counterpartyHandles: ["urn:li:member:7"],
            counterpartyNames: ["Sam Growth"], userReplied: false,
            inboundTexts: [long, long], inboundCount: 2))
        #expect(!v.isLikelyHuman)   // monologue +2, links +1, one-way +1
    }

    @Test("A salesperson you actually talk to stays visible (reciprocity wins)")
    func repliedSalesperson() {
        let v = HumanThreadClassifier.classify(S(
            platform: .linkedin, counterpartyHandles: ["urn:li:member:5"],
            counterpartyNames: ["Dana Vendor"], userReplied: true,
            inboundTexts: ["we help companies with exactly this — worth a chat?",
                           "great, sending the contract over now"],
            inboundCount: 2))
        #expect(v.isLikelyHuman)
    }

    @Test("A real person reaching out first, casually, is NOT cold outreach")
    func genuineFirstContact() {
        let v = HumanThreadClassifier.classify(S(
            platform: .linkedin, counterpartyHandles: ["urn:li:member:3"],
            counterpartyNames: ["Chris Park"], userReplied: false,
            inboundTexts: ["yo good to see you on linkedin. saw ur recent post lol"],
            inboundCount: 1))
        #expect(v.isLikelyHuman)
    }
}

@Suite("Transactional-email hardening (v2) — event registrations + product notifications")
struct TransactionalEmailTests {
    typealias S = HumanThreadClassifier.HumanSignals

    @Test("Classifier version is 2 — the app keys its verdict cache on it")
    func version() {
        #expect(HumanThreadClassifier.version == 2)
    }

    @Test("The Poker Night leak: registration email from an event platform is hidden")
    func pokerNightRegistration() {
        let v = HumanThreadClassifier.classify(S(
            platform: .gmail, counterpartyHandles: ["events@partiful.com"],
            counterpartyNames: ["Partiful"], userReplied: false,
            inboundTexts: ["You've got a spot at Poker Night"], inboundCount: 1,
            subjectOrTitle: "Registration approved for Poker Night"))
        #expect(!v.isLikelyHuman)
        #expect(v.score >= HumanThreadClassifier.threshold)
    }

    @Test("The product-notification leak is hidden WITHOUT a server hint")
    func productNotification() {
        // "Your influencer chad is ready ✨" from team@ — no List-Unsubscribe
        // header, so serverAutomatedHint is false; the v2 rules alone catch it.
        let v = HumanThreadClassifier.classify(S(
            platform: .gmail, counterpartyHandles: ["team@chadhq.com"],
            counterpartyNames: ["Chad"], userReplied: false,
            inboundTexts: ["Your influencer chad is ready to view."], inboundCount: 1,
            subjectOrTitle: "Your influencer chad is ready ✨"))
        #expect(!v.isLikelyHuman)
    }

    @Test("A first-contact human at a personal-mail domain stays visible (score 2)")
    func firstContactHuman() {
        let v = HumanThreadClassifier.classify(S(
            platform: .gmail, counterpartyHandles: ["chris.park@gmail.com"],
            counterpartyNames: ["Chris Park"], userReplied: false,
            inboundTexts: ["hey it's chris from the gym, good meeting you"], inboundCount: 1))
        #expect(v.isLikelyHuman)
        #expect(v.score == 2)   // never-corresponded +1, one-way +1 — under threshold
    }

    @Test("A friend whose text happens to start with 'your' is rescued by reciprocity")
    func casualYourText() {
        let v = HumanThreadClassifier.classify(S(
            platform: .imessage, counterpartyHandles: ["+15551234567"],
            counterpartyNames: ["Sam Rivera"], hasResolvedPerson: true, userReplied: true,
            inboundTexts: ["your package arrived lol"], inboundCount: 1))
        #expect(v.isLikelyHuman)
    }

    @Test("A contact NAMED like a service ('Events Guy') you reply to is human")
    func serviceyNameOnIMessage() {
        let v = HumanThreadClassifier.classify(S(
            platform: .imessage, counterpartyHandles: ["+15557770000"],
            counterpartyNames: ["Events Guy"], userReplied: true,
            inboundTexts: ["can you still make it tonight?"], inboundCount: 1))
        #expect(v.isLikelyHuman)
    }

    @Test("hello@ a business you actually reply to stays visible — R1 is soft, not hard")
    func repliedServiceLocalpart() {
        let v = HumanThreadClassifier.classify(S(
            platform: .gmail, counterpartyHandles: ["hello@realbusiness.com"],
            counterpartyNames: ["Real Business"], userReplied: true,
            inboundTexts: ["Sure, we can do Thursday — see you then!"], inboundCount: 1))
        #expect(v.isLikelyHuman)
    }

    @Test("userEverMessagedSender damps the never-corresponded rule")
    func everMessagedDampsR2() {
        // A generic (non-person-style) corporate sender — a person-shaped one is
        // now damped to +1 by design (see the first-contact tests below).
        var s = S(platform: .gmail, counterpartyHandles: ["billing-updates@acmecorp.com"],
                  counterpartyNames: ["Acme Corp"], userReplied: false,
                  inboundTexts: ["following up on the contract"], inboundCount: 1)
        // Generic one-way email you never wrote to → hidden (+2 R2, +1 one-way).
        #expect(!HumanThreadClassifier.classify(s).isLikelyHuman)
        // …but you HAVE written to them in another thread → shown.
        s.userEverMessagedSender = true
        #expect(HumanThreadClassifier.classify(s).isLikelyHuman)
    }

    @Test("A first-contact human writing from a WORK address stays visible (person-style localpart)")
    func firstContactHumanWorkAddress() {
        // jordan.lee@acme-corp.com, "Jordan Lee" — a recruiter/colleague/event
        // contact writing from work is exactly the relationship this app is for.
        let v = HumanThreadClassifier.classify(S(
            platform: .gmail, counterpartyHandles: ["jordan.lee@acme-corp.com"],
            counterpartyNames: ["Jordan Lee"], userReplied: false,
            inboundTexts: ["great meeting you at the summit — coffee next week?"],
            inboundCount: 1))
        #expect(v.isLikelyHuman)
        #expect(v.score == 2)   // R2 damped to +1, one-way +1 — under threshold
    }

    @Test("A templated-looking subject from a person-like sender does NOT score (R3 damper)")
    func templatedSubjectDampedForPersonLikeSender() {
        // "Thanks for the intro!" trips the templated-subject anchor, but the
        // sender is a human at a personal-mail domain — a machine subject rule
        // must not hide a person's first email.
        let v = HumanThreadClassifier.classify(S(
            platform: .gmail, counterpartyHandles: ["jane.doe@gmail.com"],
            counterpartyNames: ["Jane Doe"], userReplied: false,
            inboundTexts: ["Thanks so much for introducing me to Priya!"], inboundCount: 1,
            subjectOrTitle: "Thanks for the intro!"))
        #expect(v.isLikelyHuman)
    }

    @Test("The same templated subject from a service sender still scores → hidden")
    func templatedSubjectStillCatchesServiceSenders() {
        let v = HumanThreadClassifier.classify(S(
            platform: .gmail, counterpartyHandles: ["team@notion.so"],
            counterpartyNames: ["Notion"], userReplied: false,
            inboundTexts: ["Your workspace is ready — jump in."], inboundCount: 1,
            subjectOrTitle: "Your workspace is ready ✨"))
        #expect(!v.isLikelyHuman)
    }

    @Test("Two-token localparts made of service words are NOT person-style")
    func serviceWordLocalpartNotPersonal() {
        // support.team@ is a mailbox function, not a first.last human shape.
        #expect(!HumanThreadClassifier.hasPersonalStyleLocalpart(
            "support.team@vendor.com", names: ["Vendor"]))
        // …while an actual first.last stays person-style.
        #expect(HumanThreadClassifier.hasPersonalStyleLocalpart(
            "jordan.lee@acme-corp.com", names: ["Jordan Lee"]))
    }

    @Test("Service localparts match EXACTLY on the collapsed localpart: hi@ yes, hillary@ no")
    func exactLocalpartMatch() {
        #expect(HumanThreadClassifier.isServiceLocalpart("hi@x.com"))
        #expect(HumanThreadClassifier.isServiceLocalpart("no.tifications@x.com") == false)
        #expect(!HumanThreadClassifier.isServiceLocalpart("hillary@x.com"))
        #expect(HumanThreadClassifier.isServiceLocalpart("e.vents@pokernight.com"))   // dots collapse
    }

    @Test("Templated subjects are damped by casual markers — no machine writes 'lol'")
    func templatedSubjectDamper() {
        #expect(HumanThreadClassifier.looksTemplatedSubject("registration approved for poker night"))
        #expect(HumanThreadClassifier.looksTemplatedSubject("your order has shipped"))
        #expect(!HumanThreadClassifier.looksTemplatedSubject("your face when you see this lol"))
        #expect(!HumanThreadClassifier.looksTemplatedSubject("omg did you see the invoice??"))
    }

    @Test("ESP + bulk-subdomain shapes hit; plain providers don't")
    func espDomains() {
        #expect(HumanThreadClassifier.isESPSenderDomain("rsvp@lu.ma"))
        #expect(HumanThreadClassifier.isESPSenderDomain("x@em123.sendgrid.net"))
        #expect(HumanThreadClassifier.isESPSenderDomain("updates@mail.instagram.com"))
        #expect(!HumanThreadClassifier.isESPSenderDomain("aunt.carol@mail.com"))   // 2 labels ≠ subdomain
        #expect(!HumanThreadClassifier.isESPSenderDomain("chris@gmail.com"))
    }
}

@Suite("Topic classifier — Kinso-style labels, locally")
struct TopicClassifierTests {
    @Test("Clear topics label; small talk stays unlabeled")
    func basics() {
        #expect(TopicClassifier.classify(
            ["we're hiring for the role", "can you send your resume before the interview"]) == "Hiring")
        #expect(TopicClassifier.classify(
            ["dinner tonight?", "lunch tomorrow works", "or coffee this weekend"]) == "Plans")
        #expect(TopicClassifier.classify(
            ["you owe me for the airbnb", "venmo me when you can"]) == "Money")
        #expect(TopicClassifier.classify(["ok", "lol", "yeah"]) == nil)   // no label > wrong label
        #expect(TopicClassifier.classify([]) == nil)
    }

    @Test("One stray keyword isn't enough — labels need two hits")
    func threshold() {
        #expect(TopicClassifier.classify(["that meeting was wild lol"]) == nil)
    }
}

@Suite("Fast filters + related threads")
struct FilterRelatedTests {
    private func thread(_ platform: Platform, _ n: Int) -> OsmoThread {
        OsmoThread(id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!,
                   updatedAt: Date(), deviceSeq: 0, platform: platform,
                   platformThreadID: "t\(n)", title: "T\(n)", isGroup: false, lastMessageAt: Date())
    }

    @Test("Unanswered keeps only threads awaiting the user's reply")
    func unanswered() {
        let a = thread(.imessage, 1), b = thread(.slack, 2)
        let out = InboxFilter.unanswered([a, b]) { $0 == a.id }
        #expect(out.map(\.id) == [a.id])
    }

    @Test("Topic filter matches exactly; unlabeled threads never match")
    func topicFilter() {
        let a = thread(.imessage, 1), b = thread(.slack, 2), c = thread(.gmail, 3)
        let topics: [UUID: String] = [a.id: "Plans", b.id: "Money"]
        let out = InboxFilter.topic([a, b, c], label: "Plans") { topics[$0] }
        #expect(out.map(\.id) == [a.id])
        #expect(InboxFilter.presentTopics(in: [a, b, c]) { topics[$0] } == ["Money", "Plans"])
    }

    @Test("Related = same person first (cross-platform), then same topic")
    func related() {
        let open = thread(.imessage, 1)
        let samePerson = thread(.linkedin, 2)     // the identity-graph link
        let sameTopic = thread(.slack, 3)
        let unrelated = thread(.gmail, 4)
        let person = UUID()
        let out = RelatedThreads.find(
            for: open.id, in: [open, samePerson, sameTopic, unrelated],
            personOf: { [open.id: person, samePerson.id: person][$0] },
            topicOf: { [open.id: "Plans", sameTopic.id: "Plans", unrelated.id: "Money"][$0] })
        #expect(out.map(\.id) == [samePerson.id, sameTopic.id])
    }

    @Test("No person + no topic → nothing related (never random)")
    func nothingRelated() {
        let open = thread(.imessage, 1), other = thread(.slack, 2)
        let out = RelatedThreads.find(for: open.id, in: [open, other],
                                      personOf: { _ in nil }, topicOf: { _ in nil })
        #expect(out.isEmpty)
    }
}

@Suite("Automated evidence — server hint (Gmail) + LLM read (ThreadIntel)")
struct AutomatedEvidenceTests {
    typealias S = HumanThreadClassifier.HumanSignals

    @Test("serverAutomatedHint alone clears the threshold on an otherwise-quiet thread")
    func serverHintAlone() {
        let v = HumanThreadClassifier.classify(S(
            platform: .gmail, counterpartyHandles: ["instagram.alerts@mail.instagram.com"],
            counterpartyNames: ["Instagram"], userReplied: false,
            inboundTexts: ["Someone new followed you."], inboundCount: 1,
            serverAutomatedHint: true))
        #expect(!v.isLikelyHuman)
        #expect(v.reason == "newsletter / bulk sender")
    }

    @Test("llmSaysAutomated alone clears the threshold")
    func llmHintAlone() {
        // A handle that does NOT trip the hard-coded automated-localpart list
        // (that's a separate, earlier override) — isolates the LLM signal.
        let v = HumanThreadClassifier.classify(S(
            platform: .gmail, counterpartyHandles: ["hello@example.com"],
            counterpartyNames: ["Example"], userReplied: false,
            inboundTexts: ["Here's what's new this week."], inboundCount: 1,
            llmSaysAutomated: true))
        #expect(!v.isLikelyHuman)
        #expect(v.reason == "AI: automated sender")
    }

    @Test("llmSaysAutomated == false does not add any evidence")
    func llmHintFalseIsNeutral() {
        let v = HumanThreadClassifier.classify(S(
            platform: .imessage, counterpartyHandles: ["+15551234567"],
            counterpartyNames: ["Sarah Chen"], hasResolvedPerson: true, userReplied: false,
            inboundTexts: ["hey it's sarah"], inboundCount: 1,
            llmSaysAutomated: false))
        #expect(v.isLikelyHuman)
    }

    @Test("Reciprocity still wins: a real reply rescues the thread even with a bulk header present")
    func reciprocityStillWinsOverAutomatedHint() {
        // e.g. a business newsletter you also get real replies from.
        let v = HumanThreadClassifier.classify(S(
            platform: .gmail, counterpartyHandles: ["hello@realbusiness.com"],
            counterpartyNames: ["Real Business"], userReplied: true,
            inboundTexts: ["Thanks for reaching out, happy to help!"], inboundCount: 1,
            serverAutomatedHint: true))
        #expect(v.isLikelyHuman)
    }

    @Test("The three real leaked examples: server hint now catches what snippet-only text missed")
    func regressionRealLeakedExamples() {
        // "The anti-sunscreen movement…" newsletter — bland snippet, but the
        // server hint (List-Unsubscribe) is now available.
        let newsletter = HumanThreadClassifier.classify(S(
            platform: .gmail, counterpartyHandles: ["news@example.com"],
            counterpartyNames: ["Example News"], userReplied: false,
            inboundTexts: ["The anti-sunscreen movement is gaining steam this summer."],
            inboundCount: 1, serverAutomatedHint: true))
        #expect(!newsletter.isLikelyHuman)

        // "New login to Instagram from Chrome…" security alert — service-shaped
        // sender, bland body; server hint decisive.
        let securityAlert = HumanThreadClassifier.classify(S(
            platform: .gmail, counterpartyHandles: ["security-notifications@mail.instagram.com"],
            counterpartyNames: ["Instagram"], userReplied: false,
            inboundTexts: ["New login to Instagram from Chrome on Mac."],
            inboundCount: 1, serverAutomatedHint: true))
        #expect(!securityAlert.isLikelyHuman)

        // "Here's your verification code 8…" — the deterministic OTP regex
        // already catches most of these on its own; confirm it still does even
        // without the server hint (belt-and-suspenders).
        let otp = HumanThreadClassifier.classify(S(
            platform: .gmail, counterpartyHandles: ["noreply@example.com"],
            counterpartyNames: ["Example"], userReplied: false,
            inboundTexts: ["Here's your verification code 483920."], inboundCount: 1))
        #expect(!otp.isLikelyHuman)
    }
}
