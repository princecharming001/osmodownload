import Foundation
import OsmoCore

/// The one call the app/overlay makes to get three takes: plan (psychology) →
/// safety gate → generate (mock or proxy) → parse into labeled takes. Keyless by
/// default via the router.
public struct SuggestionService: Sendable {
    let brain: OsmoBrain
    let generator: Generator

    public init(generator: Generator = GeneratorRouter(live: nil), brain: OsmoBrain = OsmoBrain()) {
        self.generator = generator
        self.brain = brain
    }

    public struct Result: Sendable {
        public var set: SuggestionSet
        public var plan: SuggestionPlan
    }

    /// Draft three takes for a moment. Throws `GenerationError.refusedBySafety`
    /// when the request crosses the manipulation guardrail.
    public func suggest(_ context: SuggestionContext, count: Int = 3) async throws -> Result {
        let plan = brain.plan(context)
        if case let .refuse(reason) = plan.safety {
            throw GenerationError.refusedBySafety(reason)
        }
        let raw = try await generator.generate(
            systemCore: plan.prompt.systemCore,
            userTurn: plan.prompt.userTurn,
            count: count)
        return Result(set: brain.parse(raw, plan: plan), plan: plan)
    }
}
