import Testing
import Foundation
@testable import OsmoBrain

@Suite("Ask Osmo — grounded Q&A composition")
struct AskTests {
    @Test("Compose grounds the prompt in people + snippets + the question")
    func compose() {
        let ctx = AskContext(
            question: "who do I know in tech in SF?",
            snippets: ["[LinkedIn · Jay Pao · 6/20/26] moved to SF for the anthropic gig"],
            people: ["Jay Pao · LinkedIn/iMessage · Your turn · goal: referral"])
        let p = Ask.compose(ctx)
        #expect(p.systemCore == Ask.systemCore)         // stable → cacheable
        #expect(p.userTurn.contains("who do I know in tech in SF?"))
        #expect(p.userTurn.contains("Jay Pao · LinkedIn/iMessage"))
        #expect(p.userTurn.contains("anthropic gig"))
        #expect(p.systemCore.contains("never invent"))  // refusal-biased
    }

    @Test("Empty retrieval still composes (model must say it can't see it)")
    func emptyRetrieval() {
        let p = Ask.compose(AskContext(question: "what did Mia say?"))
        #expect(p.userTurn.contains("QUESTION: what did Mia say?"))
        #expect(!p.userTurn.contains("SNIPPETS"))
    }
}

@Suite("Dossier — the contact brief")
struct DossierTests {
    @Test("parseResult splits ABOUT/REMEMBER with bullets stripped")
    func parse() {
        let raw = """
        ABOUT: Your closest college friend; things have cooled a little lately.
        REMEMBER:
        - Owes you the airbnb money from Tahoe
        - Her sister's wedding is next month
        """
        let r = Dossier.parseResult(raw)
        #expect(r?.about == "Your closest college friend; things have cooled a little lately.")
        #expect(r?.remember == ["Owes you the airbnb money from Tahoe",
                                "Her sister's wedding is next month"])
    }

    @Test("Headerless output is treated as ABOUT (loose models degrade safely)")
    func headerless() {
        let r = Dossier.parseResult("A vendor contact from the conference.")
        #expect(r?.about == "A vendor contact from the conference.")
        #expect(r?.remember.isEmpty == true)
        #expect(Dossier.parseResult("") == nil)
    }

    @Test("Fallback builds an honest brief from local signals only")
    func fallback() {
        let ctx = DossierContext(
            personName: "Sam", platforms: ["iMessage", "LinkedIn"],
            goalText: "get the referral", memoryNote: "Met at hackathon\nLoves F1",
            styleChips: ["Dry", "Fast replies"],
            trajectoryDriver: "their messages have dropped off lately",
            transcript: [ThreadTurn(fromMe: false, text: "did you send it yet?")])
        let r = Dossier.fallback(ctx)
        #expect(r.about.contains("iMessage + LinkedIn"))
        #expect(r.about.contains("dropped off"))
        #expect(r.remember.contains("Your goal: get the referral"))
        #expect(r.remember.contains { $0.contains("Met at hackathon") })
        #expect(r.remember.contains { $0.contains("did you send it yet?") })
    }
}

@Suite("Dossier — public-profile enrichment sections")
struct DossierEnrichmentTests {
    @Test("Compose includes PUBLIC PROFILE and FROM THE WEB when populated")
    func composeWithProfile() {
        let ctx = DossierContext(
            personName: "Maya Render",
            headline: "Head of Growth at Reelio",
            company: "Reelio", location: "San Francisco, CA",
            profileSummary: "Ships fast, measures everything.",
            positions: ["Head of Growth at Reelio (2023–present)"],
            education: ["UC Berkeley — BA (2014–2018)"],
            webFacts: ["Maya spoke on a growth panel about retention."])
        let p = Dossier.compose(ctx)
        #expect(p.userTurn.contains("PUBLIC PROFILE (LinkedIn):"))
        #expect(p.userTurn.contains("Headline: Head of Growth at Reelio"))
        #expect(p.userTurn.contains("At: Reelio · San Francisco, CA"))
        #expect(p.userTurn.contains("FROM THE WEB (public mentions):"))
        #expect(p.userTurn.contains("- Maya spoke on a growth panel"))
        #expect(p.systemCore.contains("PUBLIC PROFILE"))   // grounding sentence
    }

    @Test("No enrichment → no section headers leak into the prompt")
    func composeWithout() {
        let p = Dossier.compose(DossierContext(personName: "Sam"))
        #expect(!p.userTurn.contains("PUBLIC PROFILE"))
        #expect(!p.userTurn.contains("FROM THE WEB"))
    }

    @Test("Fallback leads ABOUT with the headline + location")
    func fallbackHeadlineFirst() {
        let r = Dossier.fallback(DossierContext(
            personName: "Maya", platforms: ["iMessage"],
            headline: "Head of Growth at Reelio", location: "San Francisco, CA"))
        #expect(r.about.hasPrefix("Head of Growth at Reelio. Based in San Francisco, CA."))
        #expect(r.about.contains("You talk on iMessage."))
    }
}

@Suite("Draft context — WHO THEY ARE line")
struct PartnerBackgroundTests {
    @Test("Composer emits the line only when background is present")
    func emission() {
        let read = ThreadRead.read([ThreadTurn(fromMe: false, text: "hey")], now: Date())
        let strategy = Strategy.plan(move: .checkIn, goalKind: .maintainCadence,
                                     register: RelationshipRegister.infer(from: "college friend"), read: read)
        let with = PromptComposer.compose(
            relationshipLabel: "college friend", goalText: nil, goalKind: .maintainCadence,
            toneHint: nil, boundaries: [], selfContext: nil, relationshipMemory: nil,
            transcript: [], userIntent: nil, strategy: strategy, read: read,
            partnerBackground: "Head of Growth at Reelio, San Francisco")
        #expect(with.userTurn.contains("WHO THEY ARE: Head of Growth at Reelio"))

        let without = PromptComposer.compose(
            relationshipLabel: "college friend", goalText: nil, goalKind: .maintainCadence,
            toneHint: nil, boundaries: [], selfContext: nil, relationshipMemory: nil,
            transcript: [], userIntent: nil, strategy: strategy, read: read)
        #expect(!without.userTurn.contains("WHO THEY ARE"))
    }
}
