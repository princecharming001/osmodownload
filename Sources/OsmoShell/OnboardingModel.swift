import Foundation

/// The onboarding flow's logic, independent of SwiftUI — steps, skip semantics,
/// completion, and permission-driven auto-advance. The view renders `step`; the
/// controller polls `AXIsProcessTrusted` and feeds `permissionGranted`.
public final class OnboardingModel: @unchecked Sendable {

    public enum Step: Int, CaseIterable, Sendable {
        case welcome, hotkey, permission, practice, connect, finish

        public var title: String {
            switch self {
            case .welcome:    return "Every conversation, remembered."
            case .hotkey:     return "Your summon key"
            case .permission: return "One permission"
            case .practice:   return "Try it right now"
            case .connect:    return "Bring your conversations"
            case .finish:     return "You're set"
            }
        }
    }

    public private(set) var step: Step = .welcome
    /// Steps the user skipped — surfaced later as a resume checklist.
    public private(set) var skipped: Set<Step> = []
    public private(set) var completed = false

    public init(start: Step = .welcome) { self.step = start }

    public var isFirst: Bool { step == Step.allCases.first }
    public var isLast: Bool { step == Step.allCases.last }
    public var progress: Double {
        Double(step.rawValue) / Double(Step.allCases.count - 1)
    }

    /// Advance to the next step, or complete on the last one.
    @discardableResult
    public func advance() -> Step {
        if let next = Step(rawValue: step.rawValue + 1) {
            step = next
        } else {
            completed = true
        }
        return step
    }

    /// Skip the current step (recorded) and advance.
    @discardableResult
    public func skip() -> Step {
        skipped.insert(step)
        return advance()
    }

    public func back() {
        if let prev = Step(rawValue: step.rawValue - 1) { step = prev }
    }

    /// Called by the permission poller. When we're on the permission step and it
    /// flips to granted, auto-advance (the caller adds the visual green-check
    /// delay). Returns true if this triggered an advance.
    @discardableResult
    public func permissionGranted() -> Bool {
        guard step == .permission else { return false }
        skipped.remove(.permission)
        advance()
        return true
    }

    /// Jump straight to a step (e.g. "replay from settings" or resume).
    public func goTo(_ target: Step) { step = target }
}
