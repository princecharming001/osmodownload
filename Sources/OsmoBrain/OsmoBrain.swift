import Foundation
import OsmoCore

/// Everything the engine needs to draft a message. The app/overlay builds this
/// from the identity graph, the active project, relationship memory, and the real
/// thread (from the store or the overlay's screen-read).
public struct SuggestionContext: Sendable {
    public var relationshipLabel: String
    public var platform: Platform
    public var goalText: String?
    public var toneHint: String?
    public var boundaries: [String]
    public var selfContext: String?
    public var relationshipMemory: String?
    public var transcript: [ThreadTurn]
    /// Optional explicit intent ("apologize for missing the call"); when nil the
    /// move is inferred from the thread.
    public var userIntent: String?
    /// Public identity from enrichment ("Head of Growth at Reelio, SF") — lets
    /// drafts stop treating a VC and a gym buddy identically.
    public var partnerBackground: String?

    public init(relationshipLabel: String, platform: Platform,
                goalText: String? = nil, toneHint: String? = nil,
                boundaries: [String] = [], selfContext: String? = nil,
                relationshipMemory: String? = nil, transcript: [ThreadTurn] = [],
                userIntent: String? = nil, partnerBackground: String? = nil) {
        self.relationshipLabel = relationshipLabel
        self.platform = platform
        self.goalText = goalText
        self.toneHint = toneHint
        self.boundaries = boundaries
        self.selfContext = selfContext
        self.relationshipMemory = relationshipMemory
        self.transcript = transcript
        self.userIntent = userIntent
        self.partnerBackground = partnerBackground
    }
}

/// The engine's plan for a moment: the psychology it chose, the thread read, the
/// composed (cacheable core + volatile turn) prompt, and the safety verdict.
public struct SuggestionPlan: Sendable {
    public var strategy: StrategyPlan
    public var read: ThreadRead
    public var prompt: ComposedPrompt
    public var safety: Safety.Verdict
}

/// The Osmo suggestion engine — goal-directed, thread-grounded, psychology-first.
/// Built natively for the pivot (not ported from the iOS keyboard). Pure and
/// deterministic up to the model call: `plan` produces everything to send to the
/// AI client; `parse` turns the model's output into three labeled takes with the
/// lead technique's rationale attached.
public struct OsmoBrain: Sendable {
    public init() {}

    public func plan(_ context: SuggestionContext, now: Date = Date()) -> SuggestionPlan {
        let register = RelationshipRegister.infer(from: context.relationshipLabel)
        let goalKind = GoalKind.classify(context.goalText)
        let read = ThreadRead.read(context.transcript, now: now)
        // Move: explicit intent wins; else infer from their last message (a reply)
        // or fall back to a plain check-in when we're initiating.
        let move: Move = {
            if let intent = context.userIntent, Move.classify(intent) != .plain {
                return Move.classify(intent)
            }
            if read.ball == .theirs { return .answer }
            return context.goalText != nil ? .ask : .checkIn
        }()

        let strategy = Strategy.plan(move: move, goalKind: goalKind, register: register, read: read)
        let prompt = PromptComposer.compose(
            relationshipLabel: context.relationshipLabel,
            goalText: context.goalText, goalKind: goalKind, toneHint: context.toneHint,
            boundaries: context.boundaries, selfContext: context.selfContext,
            relationshipMemory: context.relationshipMemory, transcript: context.transcript,
            userIntent: context.userIntent, strategy: strategy, read: read, now: now,
            partnerBackground: context.partnerBackground)
        let safety = Safety.check(goal: context.goalText, intent: context.userIntent,
                                  transcript: read.theirLastText)
        return SuggestionPlan(strategy: strategy, read: read, prompt: prompt, safety: safety)
    }

    /// Turn raw model output into three labeled takes, seeding the first take's
    /// "why this works" from the plan's lead technique.
    public func parse(_ raw: String, plan: SuggestionPlan) -> SuggestionSet {
        let leadWhy = plan.strategy.techniques.first.map { "\($0.name): \($0.why)" }
        return SuggestionSet.parse(raw, leadWhy: leadWhy)
    }
}
