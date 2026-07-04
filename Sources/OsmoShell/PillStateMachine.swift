import Foundation
import OsmoCore

/// What the pill knows about the moment the user summoned it — assembled by the
/// app layer from typing detection (or the onboarding practice box). Pure value
/// so the state machine + tests never touch AppKit.
public struct PillContext: Equatable, Sendable {
    public var bundleID: String?
    public var platform: Platform?
    public var partnerName: String?
    public var draftText: String?
    public var matchedThreadID: UUID?
    public var sourceURL: String?
    public var isPractice: Bool

    public init(bundleID: String? = nil, platform: Platform? = nil, partnerName: String? = nil,
                draftText: String? = nil, matchedThreadID: UUID? = nil, sourceURL: String? = nil,
                isPractice: Bool = false) {
        self.bundleID = bundleID; self.platform = platform; self.partnerName = partnerName
        self.draftText = draftText; self.matchedThreadID = matchedThreadID
        self.sourceURL = sourceURL; self.isPractice = isPractice
    }

    /// True when we actually detected a conversation (vs. a bare hotkey-summon
    /// that drafts from the top queue card). Drives whether a collapse lands on
    /// `.ready` (keep the hint) or `.idle` (nothing to hint).
    public var isMeaningful: Bool {
        platform != nil || partnerName != nil || matchedThreadID != nil || isPractice
    }
}

/// The pill's visible state. `hidden` = no panel; `idle` = the small pill with
/// no detected conversation; `ready` = pill hinting a detected partner;
/// `expanded`/`generating` = the panel is open.
public enum PillState: Equatable, Sendable {
    case hidden
    case idle
    case ready(PillContext)
    case expanded(PillContext)
    case generating(PillContext)

    public var isExpanded: Bool {
        switch self { case .expanded, .generating: return true; default: return false }
    }
    public var context: PillContext? {
        switch self {
        case .ready(let c), .expanded(let c), .generating(let c): return c
        default: return nil
        }
    }
}

/// Pure transitions — the unit-testable core of the pill. The controller owns
/// panel/animation/side-effects; this owns the logic.
public enum PillStateMachine {
    public enum Event: Equatable, Sendable {
        case hotkey                          // ⌥Space (or rebound)
        case detected(PillContext?)          // typing detector; nil = context left
        case tapPill                         // click the collapsed pill
        case escape                          // collapse
        case generationStarted
        case generationFinished
        case hide                            // e.g. app quit / user dismiss
    }

    public static func reduce(_ state: PillState, _ event: Event) -> PillState {
        switch event {
        case .hotkey:
            switch state {
            case .hidden:            return .idle
            case .idle:              return .generating(PillContext())   // draft from top queue card
            case .ready(let c):      return .generating(c)
            case .expanded, .generating:
                // Toggle: collapse back to ready (keep context) or idle.
                return collapseTarget(state.context)
            }

        case .detected(let context):
            switch state {
            case .expanded, .generating:
                return state   // don't yank an open panel out from under the user
            case .hidden, .idle, .ready:
                guard let context else {
                    // Context left the field → fall back to a plain idle pill.
                    return .idle
                }
                return .ready(context)
            }

        case .tapPill:
            switch state {
            case .ready(let c):      return .generating(c)
            case .idle:              return .generating(PillContext())
            default:                 return state
            }

        case .escape:
            if state.isExpanded { return state.context.map(PillState.ready) ?? .idle }
            return state

        case .generationStarted:
            if let c = state.context { return .generating(c) }
            return state

        case .generationFinished:
            if let c = state.context { return .expanded(c) }
            return state

        case .hide:
            return .hidden
        }
    }

    /// Collapsing keeps a detected-conversation hint (`.ready`); a bare summon
    /// with no real context collapses all the way to `.idle`.
    private static func collapseTarget(_ context: PillContext?) -> PillState {
        guard let context, context.isMeaningful else { return .idle }
        return .ready(context)
    }
}
